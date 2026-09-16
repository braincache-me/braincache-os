import Foundation

/// Common interface for live audio-streaming clients used by
/// `VoiceTranscriptionService`. Both `RealtimeTranscriptionClient` (which
/// streams source-language transcripts) and `RealtimeTranslationClient`
/// (which streams translated text) conform to it so the service can swap
/// implementations at session start without branching everywhere.
protocol RealtimeAudioStreamingClient: AnyObject {
    var source: RealtimeTranscriptionClient.Source { get }

    var onPartial: ((String) -> Void)? { get set }
    var onCompleted: ((String) -> Void)? { get set }
    var onStateChange: ((RealtimeTranscriptionClient.State) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start()
    func sendAudio(_ pcm16: Data)
    func stop()
    func cancel()
}

extension RealtimeTranscriptionClient: RealtimeAudioStreamingClient {}

struct RealtimeAudioResponseStall: Equatable {
    var activeAge: TimeInterval
    var silentAge: TimeInterval
}

/// Tracks the case where audio is actively flowing to a realtime session but
/// transcript text has stopped coming back. This intentionally sits below
/// `VoiceTranscriptionService`: mic chunks that are suppressed by the echo gate
/// never reach the realtime client, so they do not count as active outgoing mic
/// audio here.
struct RealtimeAudioResponseWatchdog {
    var stallInterval: TimeInterval = 10
    var activeAudioRMSThreshold: Float = 0.01
    var activeAudioGapResetInterval: TimeInterval = 2

    private(set) var activeAudioStartedAt: Date?
    private(set) var lastActiveAudioAt: Date?
    private(set) var lastTextReceivedAt: Date?

    mutating func reset() {
        activeAudioStartedAt = nil
        lastActiveAudioAt = nil
        lastTextReceivedAt = nil
    }

    mutating func noteTextResponse(now: Date = Date()) {
        lastTextReceivedAt = now
        activeAudioStartedAt = nil
        lastActiveAudioAt = nil
    }

    mutating func noteOutgoingAudio(_ pcm16: Data, now: Date = Date()) {
        guard Self.pcm16RMS(pcm16) >= activeAudioRMSThreshold else { return }
        if let lastActiveAudioAt,
           now.timeIntervalSince(lastActiveAudioAt) <= activeAudioGapResetInterval {
            if activeAudioStartedAt == nil {
                activeAudioStartedAt = now
            }
        } else {
            activeAudioStartedAt = now
        }
        lastActiveAudioAt = now
    }

    mutating func stalled(now: Date = Date(), sessionReadyAt: Date?) -> RealtimeAudioResponseStall? {
        guard let activeAudioStartedAt, let lastActiveAudioAt else { return nil }

        if now.timeIntervalSince(lastActiveAudioAt) > activeAudioGapResetInterval {
            self.activeAudioStartedAt = nil
            self.lastActiveAudioAt = nil
            return nil
        }

        let lastResponse = lastTextReceivedAt ?? sessionReadyAt ?? activeAudioStartedAt
        let activeAge = now.timeIntervalSince(activeAudioStartedAt)
        let silentAge = now.timeIntervalSince(lastResponse)
        guard activeAge >= stallInterval, silentAge >= stallInterval else { return nil }
        return RealtimeAudioResponseStall(activeAge: activeAge, silentAge: silentAge)
    }

    static func pcm16RMS(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        let sumSquares = data.withUnsafeBytes { raw -> Double in
            var sum = 0.0
            for i in 0..<sampleCount {
                let byteOffset = i * 2
                let low = UInt16(raw[byteOffset])
                let high = UInt16(raw[byteOffset + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                let normalized = Double(sample) / Double(Int16.max)
                sum += normalized * normalized
            }
            return sum
        }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }
}
