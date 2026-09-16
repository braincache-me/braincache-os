import AVFoundation
import Foundation
import os

/// Parallel to ``MeetingAudioRecording`` but produces a `.txt` transcript instead
/// of an `.m4a` file. Owns its own ``VoiceTranscriptionRecorder`` and a pair of
/// ``RealtimeTranscriptionClient`` instances (mic + optional system audio) so it
/// runs independently of the singleton ``VoiceTranscriptionService`` used by
/// Space+Option dictation — the user can keep dictating while a meeting is
/// being transcribed in the background.
protocol MeetingTranscriptRecording: AnyObject {
    var isRecording: Bool { get }
    func startRecording(outputDirectory: URL) throws -> URL
    func stopRecording() -> MeetingTranscriptRecorder.RecordingResult?
}

final class MeetingTranscriptRecorder: MeetingTranscriptRecording {

    struct RecordingResult {
        let url: URL
        let duration: TimeInterval
        let relativePath: String
        let transcript: String
    }

    private(set) var isRecording: Bool = false

    private static let logger = Logger(subsystem: "com.braincache.activity", category: "transcript-recorder")

    private func log(_ message: String) {
        Self.logger.log("\(message, privacy: .public)")
        NSLog("MeetingTranscriptRecorder: %@", message)
    }

    private let recorder = VoiceTranscriptionRecorder()
    private var micClient: RealtimeTranscriptionClient?
    private var systemClient: RealtimeTranscriptionClient?

    private var outputURL: URL?
    private var relativePath: String?
    private var startTime: Date?

    // Transcript accumulation. We keep per-source partials plus a chronological
    // ordered list of finalised entries so the saved file reads like a real
    // dialogue rather than two giant monoliths.
    private struct Entry {
        let timestamp: TimeInterval
        let source: RealtimeTranscriptionClient.Source
        var text: String
        var isFinal: Bool
    }
    private var entries: [Entry] = []
    private var micPartial: String = ""
    private var systemPartial: String = ""
    private let accumulationLock = NSLock()

    private var includesSystemAudio = false

    // MARK: - Permission

    /// All three preconditions in one boolean so callers can gate the UI without
    /// reimplementing the rules. System-audio access is required because
    /// transcript mode always runs with system audio enabled (the user picked
    /// transcripts so they want both sides of the meeting).
    static var canStart: Bool {
        VoiceTranscriptionRecorder.micPermissionGranted &&
        AccessibilityChecker.isScreenRecordingGranted &&
        Settings.shared.isAIEnabled
    }

    // MARK: - Public API

    func startRecording(outputDirectory: URL) throws -> URL {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }
        guard VoiceTranscriptionRecorder.micPermissionGranted else {
            log("start aborted: microphone permission not granted")
            throw RecorderError.micPermissionDenied
        }
        guard AccessibilityChecker.isScreenRecordingGranted else {
            log("start aborted: screen-recording permission not granted (required for system audio)")
            throw RecorderError.screenRecordingPermissionDenied
        }
        guard Settings.shared.isAIEnabled else {
            log("start aborted: OpenAI API key not configured")
            throw RecorderError.apiKeyMissing
        }
        log("starting (output=\(outputDirectory.path))")

        let now = Date()
        let dayString = Self.dayString(for: now)
        let fileTimestamp = Self.fileTimestamp(for: now)
        let dayDir = outputDirectory.appendingPathComponent(dayString, isDirectory: true)

        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let fileName = "transcript_\(fileTimestamp).txt"
        let fileURL = dayDir.appendingPathComponent(fileName)
        let relPath = "\(dayString)/\(fileName)"

        outputURL = fileURL
        relativePath = relPath
        startTime = now
        entries.removeAll()
        micPartial = ""
        systemPartial = ""
        includesSystemAudio = true
        isRecording = true

        recorder.audioChunkHandler = { [weak self] data, source in
            guard let self else { return }
            switch source {
            case .mic: self.micClient?.sendAudio(data)
            case .system: self.systemClient?.sendAudio(data)
            }
        }
        recorder.includeSystemAudio = true

        let mic = makeClient(source: .mic)
        micClient = mic
        mic.start()

        let sys = makeClient(source: .system)
        systemClient = sys
        sys.start()

        do {
            try recorder.startRecording()
            log("recording underway → file=\(fileURL.lastPathComponent)")
        } catch {
            log("recorder.startRecording threw: \(error.localizedDescription)")
            shutdownClients()
            isRecording = false
            outputURL = nil
            relativePath = nil
            startTime = nil
            throw error
        }

        return fileURL
    }

    func stopRecording() -> RecordingResult? {
        guard isRecording else { return nil }
        isRecording = false

        let duration = recorder.stopRecording()

        // Politely commit the buffers so the server has a chance to send
        // closing transcripts; cap the wait so we don't block the coordinator.
        micClient?.stop()
        systemClient?.stop()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline,
              !(micPartial.isEmpty && systemPartial.isEmpty) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        // Fold any remaining partials into the entries list.
        finalizePartialIfNeeded(source: .mic)
        finalizePartialIfNeeded(source: .system)

        shutdownClients()

        let url = outputURL
        let relPath = relativePath
        outputURL = nil
        relativePath = nil
        startTime = nil

        guard let url, let relPath, duration >= 1.0 else {
            log("discarded — duration \(String(format: "%.2f", duration))s under 1s minimum")
            if let url, duration < 1.0 {
                try? FileManager.default.removeItem(at: url)
            }
            entries.removeAll()
            return nil
        }

        let text = renderTranscript()
        entries.removeAll()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("discarded — transcript empty (no speech detected by realtime API in \(String(format: "%.1f", duration))s)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            log("wrote transcript file=\(relPath) chars=\(text.count) duration=\(String(format: "%.1f", duration))s")
        } catch {
            log("failed to write transcript file: \(error.localizedDescription)")
            return nil
        }

        return RecordingResult(url: url, duration: duration, relativePath: relPath, transcript: text)
    }

    // MARK: - Realtime clients

    private func makeClient(source: RealtimeTranscriptionClient.Source) -> RealtimeTranscriptionClient {
        let client = RealtimeTranscriptionClient(
            source: source,
            model: Settings.shared.transcriptionModel
        )
        client.onPartial = { [weak self] delta in
            self?.appendPartial(delta, source: source)
        }
        client.onCompleted = { [weak self] text in
            self?.completeTranscript(text, source: source)
        }
        client.onError = { [weak self] error in
            self?.log("\(source.rawValue) realtime client error: \(error.localizedDescription)")
        }
        return client
    }

    private func shutdownClients() {
        micClient?.cancel()
        systemClient?.cancel()
        micClient = nil
        systemClient = nil
    }

    // MARK: - Transcript accumulation

    private func appendPartial(_ delta: String, source: RealtimeTranscriptionClient.Source) {
        guard !delta.isEmpty else { return }
        accumulationLock.lock()
        defer { accumulationLock.unlock() }
        switch source {
        case .mic: micPartial += delta
        case .system: systemPartial += delta
        }
    }

    private func completeTranscript(_ text: String, source: RealtimeTranscriptionClient.Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accumulationLock.lock()
        defer { accumulationLock.unlock() }
        entries.append(Entry(
            timestamp: currentTranscriptTimestamp(),
            source: source,
            text: trimmed,
            isFinal: true
        ))
        switch source {
        case .mic: micPartial = ""
        case .system: systemPartial = ""
        }
    }

    private func finalizePartialIfNeeded(source: RealtimeTranscriptionClient.Source) {
        accumulationLock.lock()
        let partial: String
        switch source {
        case .mic: partial = micPartial
        case .system: partial = systemPartial
        }
        accumulationLock.unlock()
        guard !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        completeTranscript(partial, source: source)
    }

    private func renderTranscript() -> String {
        accumulationLock.lock()
        defer { accumulationLock.unlock() }
        guard !entries.isEmpty else { return "" }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        return sorted.map { entry in
            let ts = Self.formatTimestamp(entry.timestamp)
            let tag = entry.source == .mic ? "Mic" : "Sys"
            return "[\(ts) \(tag)] \(entry.text)"
        }.joined(separator: "\n")
    }

    private func currentTranscriptTimestamp() -> TimeInterval {
        Date().timeIntervalSince(startTime ?? Date())
    }

    // MARK: - Helpers

    private static func dayString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func fileTimestamp(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH-mm-ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case micPermissionDenied
        case screenRecordingPermissionDenied
        case apiKeyMissing

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A meeting transcript is already in progress."
            case .micPermissionDenied: return "Microphone access denied."
            case .screenRecordingPermissionDenied: return "Screen Recording permission is required for system audio."
            case .apiKeyMissing: return "OpenAI API key is not configured."
            }
        }
    }
}
