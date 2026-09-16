import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures microphone audio (always) and optionally system audio. Emits 24 kHz
/// mono PCM16 chunks via streaming callbacks so the realtime transcription
/// client can ship them straight to OpenAI without intermediate WAV files.
final class VoiceTranscriptionRecorder: NSObject {

    /// Identifies which capture source produced a given audio chunk.
    enum Source {
        case mic
        case system
    }

    private(set) var isRecording = false
    var includeSystemAudio = false
    var audioLevelCallback: ((Float) -> Void)?
    /// RMS level (0…1-ish) of the system-audio capture stream. Useful for
    /// rendering a separate waveform when system audio is recorded alongside
    /// the mic. Called on the main queue.
    var systemAudioLevelCallback: ((Float) -> Void)?
    /// Receives 16-bit signed little-endian PCM at the recorder's output sample rate.
    /// Called from a private serial queue.
    var audioChunkHandler: ((Data, Source) -> Void)?
    /// Called when the optional ScreenCaptureKit system-audio stream cannot start
    /// or stops unexpectedly while recording.
    var systemAudioErrorHandler: ((Error) -> Void)?

    // Mic gating: when system audio is being captured and is louder than
    // ``micGateRMSThreshold``, the mic stream is most likely picking up echo
    // from the speakers — sending it to the transcription service would cause
    // duplicate words. We drop mic chunks for ``micGateHoldSeconds`` after the
    // last loud system frame so the gate doesn't flicker between syllables.
    private let micGateRMSThreshold: Float = 0.015
    private let micGateHoldSeconds: TimeInterval = 0.25
    private let micGateDominanceRatio: Float = 1.5
    private let micGateDominanceMinimumRMS: Float = 0.02
    private var lastSystemAudioLoudAt: CFAbsoluteTime = 0
    private var lastSystemAudioRMS: Float = 0

    private var audioEngine: AVAudioEngine?
    private var startTime: Date?

    private var scStream: SCStream?
    private var systemAudioCaptureStarting = false
    private var systemAudioCaptureGeneration = 0

    /// 24 kHz matches the OpenAI realtime API's expected PCM rate; the legacy
    /// file-based whisper-1 path also accepts this without re-resampling.
    private let outputSampleRate: Double = 24000
    private let outputChannels: AVAudioChannelCount = 1

    private let writingQueue = DispatchQueue(
        label: "com.braincache.voice-transcription-writer",
        qos: .userInitiated
    )

    private var selectedDeviceUID: String?

    // MARK: - Device Selection

    func setInputDevice(uid: String?) {
        selectedDeviceUID = uid
    }

    static func availableInputDevices() -> [(uid: String, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }

        var result: [(uid: String, name: String)] = []
        for device in devices {
            guard hasInputChannels(device) else { continue }
            guard let uid = deviceUID(device), let name = deviceName(device) else { continue }
            result.append((uid: uid, name: name))
        }
        return result
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        return bufferList.pointee.mNumberBuffers > 0
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let cfStr = value?.takeUnretainedValue() else { return nil }
        return cfStr as String
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let cfStr = value?.takeUnretainedValue() else { return nil }
        return cfStr as String
    }

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

    // MARK: - Recording

    func startRecording() throws {
        guard !isRecording else { return }
        guard Self.micPermissionGranted else {
            throw RecorderError.permissionDenied
        }
        if includeSystemAudio, !AccessibilityChecker.isScreenRecordingGranted {
            throw RecorderError.screenRecordingPermissionDenied
        }

        startTime = Date()
        isRecording = true
        lastSystemAudioLoudAt = 0
        lastSystemAudioRMS = 0

        do {
            if includeSystemAudio {
                try startSystemAudioCaptureIfNeeded()
            }
            try startMicCapture()
        } catch {
            isRecording = false
            stopSystemAudioCaptureIfNeeded()
            startTime = nil
            throw error
        }
    }

    /// Stops capture. Returns the total recorded duration so callers can record
    /// per-minute transcription cost.
    @discardableResult
    func stopRecording() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false
        stopMicCapture()
        stopSystemAudioCaptureIfNeeded()
        writingQueue.sync {}
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        startTime = nil
        return duration
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        stopMicCapture()
        stopSystemAudioCaptureIfNeeded()
        writingQueue.sync {}
        startTime = nil
    }

    var recordingDuration: TimeInterval {
        startTime.map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let uid = selectedDeviceUID {
            setAudioEngineInputDevice(engine, uid: uid)
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        let converter: AVAudioConverter?
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: outputChannels,
            interleaved: false
        )!

        if inputFormat.sampleRate != outputSampleRate || inputFormat.channelCount != outputChannels {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        try engine.start()
        audioEngine = engine
    }

    private func stopMicCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    /// Tears down the active mic engine and starts a new one so the most
    /// recently set ``selectedDeviceUID`` takes effect on an in-flight
    /// recording. System audio capture is unaffected. No-op when not
    /// currently recording.
    func restartMicCapture() throws {
        guard isRecording else { return }
        stopMicCapture()
        try startMicCapture()
    }

    private func setAudioEngineInputDevice(_ engine: AVAudioEngine, uid: String) {
        Self.setInputDevice(on: engine, uid: uid)
    }

    /// Points `engine`'s input node at the CoreAudio device with `uid`. No-op
    /// when the UID is unknown (the default input stays in place). Shared
    /// with `VoiceMediaRecorder` so the saved file uses the same mic the
    /// transcription hears.
    static func setInputDevice(on engine: AVAudioEngine, uid: String) {
        let inputNode = engine.inputNode
        var deviceID: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &devices
        ) == noErr else { return }

        for dev in devices {
            if Self.deviceUID(dev) == uid {
                deviceID = dev
                break
            }
        }

        guard deviceID != 0 else { return }
        let audioUnit = inputNode.audioUnit!
        var devID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func handleMicBuffer(
        _ micBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) {
        guard isRecording else { return }

        let rms = Self.calculateRMS(buffer: micBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.audioLevelCallback?(rms)
        }

        let bufferToShip: AVAudioPCMBuffer
        if let converter {
            let frameCapacity = AVAudioFrameCount(
                Double(micBuffer.frameLength) * (outputSampleRate / micBuffer.format.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return micBuffer
            }
            guard status != .error, error == nil else { return }
            bufferToShip = converted
        } else {
            bufferToShip = micBuffer
        }

        guard let pcm16 = Self.pcm16Data(from: bufferToShip) else { return }
        let micGateActive = isMicGateActive(micRMS: rms)
        writingQueue.async { [weak self] in
            guard let self else { return }
            // Suppress mic audio while system audio is loud to avoid the mic
            // re-transcribing whatever the speakers are playing.
            if micGateActive { return }
            self.audioChunkHandler?(pcm16, .mic)
        }
    }

    private func isMicGateActive(micRMS: Float) -> Bool {
        Self.shouldSuppressMicAudio(
            includeSystemAudio: includeSystemAudio,
            lastSystemAudioLoudAt: lastSystemAudioLoudAt,
            now: CFAbsoluteTimeGetCurrent(),
            micRMS: micRMS,
            lastSystemAudioRMS: lastSystemAudioRMS,
            loudThreshold: micGateRMSThreshold,
            holdSeconds: micGateHoldSeconds,
            micDominanceRatio: micGateDominanceRatio,
            minimumDominantMicRMS: micGateDominanceMinimumRMS
        )
    }

    static func shouldSuppressMicAudio(
        includeSystemAudio: Bool,
        lastSystemAudioLoudAt: CFAbsoluteTime,
        now: CFAbsoluteTime,
        micRMS: Float,
        lastSystemAudioRMS: Float,
        loudThreshold: Float,
        holdSeconds: TimeInterval,
        micDominanceRatio: Float,
        minimumDominantMicRMS: Float
    ) -> Bool {
        guard includeSystemAudio else { return false }
        guard lastSystemAudioLoudAt > 0 else { return false }
        guard (now - lastSystemAudioLoudAt) < holdSeconds else { return false }

        // Let real mic speech break through the echo gate when it clearly
        // dominates the current system-audio level. Without this, quiet-ish
        // system audio can keep the mic stream suppressed, so a stale mic
        // socket never sees outgoing audio and the response watchdog cannot
        // recover it.
        let dominantMicThreshold = max(loudThreshold, lastSystemAudioRMS * micDominanceRatio)
        if micRMS >= minimumDominantMicRMS, micRMS >= dominantMicThreshold {
            return false
        }

        return true
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        return sqrtf(sum / Float(frames))
    }

    /// Converts a mono float32 PCM buffer to 16-bit signed little-endian PCM bytes.
    private static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let floats = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var data = Data(count: frames * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let dst = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frames {
                let clamped = max(-1.0, min(1.0, floats[i]))
                dst[i] = Int16(clamped * 32767).littleEndian
            }
        }
        return data
    }

    // MARK: - System Audio Capture

    func startSystemAudioCaptureIfNeeded() throws {
        guard isRecording else {
            throw RecorderError.notRecording
        }
        guard AccessibilityChecker.isScreenRecordingGranted else {
            throw RecorderError.screenRecordingPermissionDenied
        }
        guard scStream == nil, !systemAudioCaptureStarting else {
            includeSystemAudio = true
            return
        }

        includeSystemAudio = true
        systemAudioCaptureStarting = true
        systemAudioCaptureGeneration += 1
        startSystemAudioCapture(generation: systemAudioCaptureGeneration)
    }

    func stopSystemAudioCaptureIfNeeded() {
        includeSystemAudio = false
        systemAudioCaptureStarting = false
        systemAudioCaptureGeneration += 1
        lastSystemAudioLoudAt = 0
        lastSystemAudioRMS = 0
        stopSystemAudioCapture()
    }

    private func startSystemAudioCapture(generation: Int) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    handleSystemAudioStartFailure(RecorderError.noDisplayAvailable, generation: generation)
                    return
                }

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
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writingQueue)
                try await stream.startCapture()

                guard isRecording,
                      includeSystemAudio,
                      systemAudioCaptureGeneration == generation else {
                    systemAudioCaptureStarting = false
                    try? await stream.stopCapture()
                    return
                }

                systemAudioCaptureStarting = false
                self.scStream = stream
            } catch {
                NSLog("VoiceTranscriptionRecorder: System audio capture failed: %@", error.localizedDescription)
                handleSystemAudioStartFailure(error, generation: generation)
            }
        }
    }

    private func stopSystemAudioCapture() {
        guard let stream = scStream else { return }
        scStream = nil
        Task { try? await stream.stopCapture() }
    }

    private func handleSystemAudioStartFailure(_ error: Error, generation: Int) {
        guard systemAudioCaptureGeneration == generation else { return }
        systemAudioCaptureStarting = false
        includeSystemAudio = false
        guard isRecording else { return }
        notifySystemAudioFailure(error)
    }

    private func notifySystemAudioFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.systemAudioErrorHandler?(error)
        }
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case permissionDenied
        case notRecording
        case screenRecordingPermissionDenied
        case noDisplayAvailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access denied."
            case .notRecording:
                return "System audio can only be toggled while a recording is active."
            case .screenRecordingPermissionDenied:
                return "Screen Recording permission is required for Sys audio. Enable BrainCache in System Settings, then quit and reopen the app."
            case .noDisplayAvailable:
                return "System audio capture failed because macOS did not report an available display."
            }
        }
    }
}

// MARK: - SCStreamOutput

extension VoiceTranscriptionRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording, includeSystemAudio else { return }
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
        let floatPtr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: outputChannels,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let outData = buffer.floatChannelData else { return }
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if isNonInterleaved || channels == 1 {
            memcpy(outData[0], floatPtr, frameCount * MemoryLayout<Float>.size)
        } else {
            for frame in 0..<frameCount {
                outData[0][frame] = floatPtr[frame * channels]
            }
        }

        let rms = Self.calculateRMS(buffer: buffer)
        lastSystemAudioRMS = rms
        if rms > micGateRMSThreshold {
            lastSystemAudioLoudAt = CFAbsoluteTimeGetCurrent()
        }
        DispatchQueue.main.async { [weak self] in
            self?.systemAudioLevelCallback?(rms)
        }

        guard let pcm16 = Self.pcm16Data(from: buffer) else { return }
        audioChunkHandler?(pcm16, .system)
    }
}

// MARK: - SCStreamDelegate

extension VoiceTranscriptionRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("VoiceTranscriptionRecorder: SCStream stopped: %@", error.localizedDescription)
        let shouldNotify = isRecording
        scStream = nil
        if shouldNotify {
            notifySystemAudioFailure(error)
        }
    }
}
