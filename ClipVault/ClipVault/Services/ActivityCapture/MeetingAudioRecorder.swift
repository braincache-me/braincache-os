import AVFoundation
import ScreenCaptureKit
import CoreMedia

protocol MeetingAudioRecording: AnyObject {
    var isRecording: Bool { get }
    func startRecording(outputDirectory: URL) throws -> URL
    func stopRecording() -> MeetingAudioRecorder.RecordingResult?
}

final class MeetingAudioRecorder: NSObject, MeetingAudioRecording {

    struct RecordingResult {
        let url: URL
        let duration: TimeInterval
        let relativePath: String
    }

    private(set) var isRecording: Bool = false

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var relativePath: String?
    private var startTime: Date?

    private let outputSampleRate: Double = 48000
    private let outputChannels: AVAudioChannelCount = 2

    private var systemAudioRingBuffer = RingBuffer()
    private let ringBufferLock = NSLock()

    private let writingQueue = DispatchQueue(
        label: "com.braincache.meeting-audio-writer",
        qos: .userInitiated
    )

    // MARK: - Permission

    static var micPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicPermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Public API

    func startRecording(outputDirectory: URL) throws -> URL {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }
        guard Self.micPermissionGranted else {
            throw RecorderError.permissionDenied
        }

        let now = Date()
        let dayString = Self.dayString(for: now)
        let fileTimestamp = Self.fileTimestamp(for: now)
        let dayDir = outputDirectory.appendingPathComponent(dayString, isDirectory: true)

        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let fileName = "meeting_\(fileTimestamp).m4a"
        let fileURL = dayDir.appendingPathComponent(fileName)
        let relPath = "\(dayString)/\(fileName)"

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: outputChannels,
            AVEncoderBitRateKey: 128_000
        ]

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        outputFile = file
        outputURL = fileURL
        relativePath = relPath
        startTime = now
        isRecording = true

        ringBufferLock.lock()
        systemAudioRingBuffer.reset()
        ringBufferLock.unlock()

        try startMicCapture()
        startSystemAudioCapture()

        return fileURL
    }

    func stopRecording() -> RecordingResult? {
        guard isRecording else { return nil }
        isRecording = false

        stopMicCapture()
        stopSystemAudioCapture()

        let url = outputURL
        let relPath = relativePath
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0

        writingQueue.sync {}
        outputFile = nil
        outputURL = nil
        relativePath = nil
        startTime = nil

        guard let url, let relPath, duration >= 3.0 else {
            if let url, duration < 3.0 {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        return RecordingResult(url: url, duration: duration, relativePath: relPath)
    }

    // MARK: - Mic capture (input-only AVAudioEngine, no output connection)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        try engine.start()
        audioEngine = engine
    }

    private func stopMicCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func handleMicBuffer(_ micBuffer: AVAudioPCMBuffer) {
        guard isRecording else { return }
        let frameCount = Int(micBuffer.frameLength)
        guard frameCount > 0 else { return }

        // Create output buffer in target format
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: outputChannels,
                interleaved: false
            )!,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let outChannelData = outputBuffer.floatChannelData else { return }
        let outCh0 = outChannelData[0]
        let outCh1 = outChannelData[1]

        // Copy mic into output buffer (handle mono→stereo)
        if let micChannelData = micBuffer.floatChannelData {
            let micChannels = Int(micBuffer.format.channelCount)
            for frame in 0..<frameCount {
                let sample = micChannelData[0][frame]
                outCh0[frame] = sample
                outCh1[frame] = micChannels > 1 ? micChannelData[1][frame] : sample
            }
        }

        // Mix in system audio from ring buffer
        ringBufferLock.lock()
        let available = systemAudioRingBuffer.availableFrames
        let toMix = min(frameCount, available)
        if toMix > 0 {
            systemAudioRingBuffer.mixInto(ch0: outCh0, ch1: outCh1, frameCount: toMix)
        }
        ringBufferLock.unlock()

        // Write mixed buffer to file
        writingQueue.async { [weak self] in
            guard let self, let file = self.outputFile else { return }
            do {
                try file.write(from: outputBuffer)
            } catch {
                NSLog("MeetingAudioRecorder: file write error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - System audio capture via ScreenCaptureKit

    private func startSystemAudioCapture() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { return }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(outputSampleRate)
                config.channelCount = Int(outputChannels)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
                try await stream.startCapture()
                self.scStream = stream
            } catch {
                NSLog("MeetingAudioRecorder: System audio capture failed: %@", error.localizedDescription)
            }
        }
    }

    private func stopSystemAudioCapture() {
        guard let stream = scStream else { return }
        scStream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    // MARK: - Helpers

    private static func dayString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func fileTimestamp(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH-mm-ss"
        return fmt.string(from: date)
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .permissionDenied: return "Microphone access denied."
            }
        }
    }
}

// MARK: - SCStreamOutput

extension MeetingAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let floatPtr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)

        ringBufferLock.lock()
        if isNonInterleaved {
            let ch0 = floatPtr
            let ch1 = channels > 1 ? floatPtr.advanced(by: frameCount) : ch0
            for frame in 0..<frameCount {
                systemAudioRingBuffer.write(sample: ch0[frame], channel: 0)
                systemAudioRingBuffer.write(sample: ch1[frame], channel: 1)
                systemAudioRingBuffer.advanceWritePosition()
            }
        } else {
            for frame in 0..<frameCount {
                let base = frame * channels
                systemAudioRingBuffer.write(sample: floatPtr[base], channel: 0)
                systemAudioRingBuffer.write(sample: channels > 1 ? floatPtr[base + 1] : floatPtr[base], channel: 1)
                systemAudioRingBuffer.advanceWritePosition()
            }
        }
        ringBufferLock.unlock()
    }
}

// MARK: - SCStreamDelegate

extension MeetingAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MeetingAudioRecorder: SCStream stopped: %@", error.localizedDescription)
        scStream = nil
    }
}

// MARK: - Ring Buffer (lock-free single-producer for system audio)

private struct RingBuffer {
    private var buffer: [[Float]]
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var count: Int = 0
    private let capacity: Int

    init(capacity: Int = 48000 * 4) {  // 4 seconds at 48kHz
        self.capacity = capacity
        self.buffer = [
            [Float](repeating: 0, count: capacity),
            [Float](repeating: 0, count: capacity)
        ]
    }

    var availableFrames: Int { count }

    mutating func reset() {
        writePos = 0
        readPos = 0
        count = 0
    }

    mutating func write(sample: Float, channel: Int) {
        guard channel < buffer.count else { return }
        buffer[channel][writePos] = sample
    }

    mutating func advanceWritePosition() {
        writePos = (writePos + 1) % capacity
        if count < capacity {
            count += 1
        } else {
            readPos = (readPos + 1) % capacity
        }
    }

    mutating func mixInto(ch0: UnsafeMutablePointer<Float>, ch1: UnsafeMutablePointer<Float>, frameCount: Int) {
        let toRead = min(frameCount, count)
        for i in 0..<toRead {
            let pos = (readPos + i) % capacity
            ch0[i] += buffer[0][pos]
            ch1[i] += buffer[1][pos]
        }
        readPos = (readPos + toRead) % capacity
        count -= toRead
    }
}
