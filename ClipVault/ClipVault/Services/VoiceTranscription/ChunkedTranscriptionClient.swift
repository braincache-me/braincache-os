import Foundation
import os

/// Posts one WAV chunk to a transcription model and returns the text.
///
/// Injected so the chunking, ordering and error policy in
/// `ChunkedTranscriptionClient` can be unit-tested without a network.
protocol ChunkedTranscriptionTransport: AnyObject {
    func transcribe(wav: Data, model: String, instruction: String) async throws -> String
}

/// Default transport: an omni chat-completions call, with one retry through
/// `OmniModelResolver` when the configured omni model ID turns out to be wrong.
final class OmniChatTranscriptionTransport: ChunkedTranscriptionTransport {

    private let client: OpenAIClient

    init(client: OpenAIClient = .shared) {
        self.client = client
    }

    func transcribe(wav: Data, model: String, instruction: String) async throws -> String {
        do {
            return try await client.transcribeAudioChunk(
                wavData: wav, model: model, instruction: instruction
            )
        } catch {
            guard OmniModelResolver.isModelNotFound(error),
                  let resolved = await OmniModelResolver.resolveAndPersist(failedModel: model, client: client)
            else { throw error }
            return try await client.transcribeAudioChunk(
                wavData: wav, model: resolved, instruction: instruction
            )
        }
    }
}

/// Transcribes live audio by cutting it into chunks and posting each one to an
/// omni chat model — the non-realtime counterpart of
/// ``RealtimeTranscriptionClient``.
///
/// Token Factory has no realtime WebSocket, so instead of streaming PCM to a
/// socket the client buffers it, cuts a chunk every
/// ``Settings/chunkedTranscriptionWindowSeconds`` at the quietest point in the
/// trailing ~1.5 s (so words aren't sliced), resamples 24 kHz → 16 kHz, wraps
/// the result in a WAV header, and sends it.
///
/// It exposes exactly the surface `VoiceTranscriptionService` already uses, so
/// everything downstream — finalize intents, transcript drafts, media
/// recording, meeting detection — is untouched.
///
/// Two deliberate behavioural notes:
/// - **No partials.** The service's pause detection would freeze a placeholder
///   partial into its own transcript entry, so only completed segments are
///   emitted.
/// - **Results are emitted in order.** Up to two requests are in flight per
///   source; ``OrderedSegmentEmitter`` parks an early finisher until its
///   predecessor lands.
final class ChunkedTranscriptionClient: RealtimeAudioStreamingClient {

    let source: RealtimeTranscriptionClient.Source

    var onPartial: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onStateChange: ((RealtimeTranscriptionClient.State) -> Void)?
    var onError: ((Error) -> Void)?

    /// RMS below which a chunk is assumed to be silence and skipped entirely.
    static let silenceRMSThreshold: Float = 0.005
    /// Sample rate the omni models are documented to prefer.
    static let targetSampleRate = 16_000
    /// Consecutive request failures tolerated before the session is failed.
    /// Transient 5xx/timeouts must not end a 40-minute meeting.
    static let maxConsecutiveFailures = 3

    private let model: String
    /// Non-nil when the chunk prompt should ask for a translation instead of a
    /// verbatim transcript.
    private let targetLanguage: String?
    private let sampleRate: Int
    private let transport: ChunkedTranscriptionTransport
    private let maxInFlight: Int
    /// Overrides `Settings.chunkedTranscriptionWindowSeconds`. Only tests pass
    /// a value; production reads the setting live so a preference change takes
    /// effect on the next chunk.
    private let windowSecondsOverride: TimeInterval?

    private let queue = DispatchQueue(label: "com.braincache.chunked-transcription", qos: .userInitiated)

    private var buffer = Data()
    private var waiting: [(sequence: Int, wav: Data)] = []
    private var inFlight = 0
    private var emitter = OrderedSegmentEmitter()
    private var consecutiveFailures = 0
    private var isStopping = false
    private var splitFinder = SilenceSplitFinder()

    private var state: RealtimeTranscriptionClient.State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    init(
        source: RealtimeTranscriptionClient.Source,
        model: String,
        targetLanguage: String? = nil,
        sampleRate: Int = 24_000,
        transport: ChunkedTranscriptionTransport = OmniChatTranscriptionTransport(),
        maxInFlight: Int = 2,
        windowSeconds: TimeInterval? = nil
    ) {
        self.source = source
        self.model = model
        self.targetLanguage = targetLanguage
        self.sampleRate = sampleRate
        self.transport = transport
        self.maxInFlight = max(1, maxInFlight)
        self.windowSecondsOverride = windowSeconds
    }

    // MARK: - RealtimeAudioStreamingClient

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .idle = self.state else { return }
            guard !Settings.shared.openAIAPIKey.isEmpty else {
                let message = "AI API key is not configured."
                self.log("start aborted: \(message)")
                self.state = .failed(message)
                self.onError?(NSError(domain: "ChunkedTranscriptionClient", code: 401,
                                      userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
            self.log("started (model=\(self.model), window=\(Settings.shared.chunkedTranscriptionWindowSeconds) s)")
            self.state = .ready
        }
    }

    func sendAudio(_ pcm16: Data) {
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            guard case .ready = self.state else { return }
            self.buffer.append(pcm16)
            self.cutChunksIfNeeded()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.isStopping = true
            self.state = .stopping
            self.flushRemainingBuffer()
            self.finishIfDrained()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.buffer.removeAll(keepingCapacity: false)
            self.waiting.removeAll(keepingCapacity: false)
            self.state = .stopped
        }
    }

    // MARK: - Chunking

    private var windowSeconds: TimeInterval {
        windowSecondsOverride ?? TimeInterval(Settings.shared.chunkedTranscriptionWindowSeconds)
    }

    private func cutChunksIfNeeded() {
        while PCM16Audio.duration(buffer, sampleRate: sampleRate) >= windowSeconds {
            let offset = splitFinder.splitOffset(in: buffer, sampleRate: sampleRate)
            guard offset > 0, offset <= buffer.count else { break }
            let chunk = buffer.prefix(offset)
            buffer = Data(buffer.dropFirst(offset))
            enqueue(Data(chunk))
        }
    }

    private func flushRemainingBuffer() {
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: false)
        enqueue(chunk)
    }

    /// Resamples, wraps and queues one chunk. Silence is dropped before a
    /// sequence number is reserved so it never stalls ordered emission.
    private func enqueue(_ pcm16: Data) {
        guard PCM16Audio.rms(pcm16) >= Self.silenceRMSThreshold else {
            logVerbose("skipping silent chunk (\(pcm16.count) bytes)")
            return
        }
        let resampled = PCM16Audio.resample(pcm16, from: sampleRate, to: Self.targetSampleRate)
        let wav = PCM16Audio.wav(pcm16: resampled, sampleRate: Self.targetSampleRate)
        let sequence = emitter.reserve()
        waiting.append((sequence: sequence, wav: wav))
        pump()
    }

    /// Starts as many queued chunks as the in-flight budget allows.
    private func pump() {
        while inFlight < maxInFlight, !waiting.isEmpty {
            let next = waiting.removeFirst()
            inFlight += 1
            let instruction = self.instruction
            let model = self.model
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await self.transport.transcribe(
                        wav: next.wav, model: model, instruction: instruction
                    )
                    self.queue.async { self.handleSuccess(sequence: next.sequence, text: text) }
                } catch {
                    self.queue.async { self.handleFailure(sequence: next.sequence, error: error) }
                }
            }
        }
    }

    private func handleSuccess(sequence: Int, text: String) {
        inFlight -= 1
        consecutiveFailures = 0
        let cleaned = ThinkTagFilter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        release(emitter.complete(sequence: sequence, text: cleaned))
        pump()
        finishIfDrained()
    }

    private func handleFailure(sequence: Int, error: Error) {
        inFlight -= 1
        consecutiveFailures += 1
        log("chunk \(sequence) failed: \(error.localizedDescription)")
        // Keep ordering intact: a dropped chunk still has to advance the queue.
        release(emitter.complete(sequence: sequence, text: ""))

        let isFatal = (error as? OpenAIError) == .apiKeyMissing
            || Self.isUnauthorized(error)
            || consecutiveFailures >= Self.maxConsecutiveFailures
        if isFatal {
            state = .failed(error.localizedDescription)
            waiting.removeAll(keepingCapacity: false)
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
            return
        }
        pump()
        finishIfDrained()
    }

    private func release(_ segments: [String]) {
        guard !segments.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for segment in segments { self.onCompleted?(segment) }
        }
    }

    private func finishIfDrained() {
        guard isStopping, inFlight == 0, waiting.isEmpty else { return }
        if case .failed = state { return }
        state = .stopped
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        guard case OpenAIError.httpError(let status, _) = error else { return false }
        return status == 401
    }

    // MARK: - Prompt

    /// The instruction sent alongside each audio chunk.
    var instruction: String {
        guard let targetLanguage, !targetLanguage.isEmpty else {
            return "Transcribe this audio verbatim. Output only the transcript."
        }
        let name = Self.languageName(for: targetLanguage)
        return "Transcribe this audio and translate it to \(name). Output only the translation."
    }

    /// Maps an ISO 639-1 code to the display name used in the prompt, falling
    /// back to the raw code for languages not in the picker list.
    static func languageName(for code: String) -> String {
        Settings.Defaults.translationLanguages
            .first { $0.code.caseInsensitiveCompare(code) == .orderedSame }?
            .name ?? code
    }

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.braincache.realtime", category: "chunked-transcription")

    private func log(_ message: String) {
        Self.logger.log("[ChunkedTranscription:\(self.source.rawValue, privacy: .public)] \(message, privacy: .public)")
    }

    private func logVerbose(_ message: String) {
        Self.logger.debug("[ChunkedTranscription:\(self.source.rawValue, privacy: .public)] \(message, privacy: .public)")
    }
}
