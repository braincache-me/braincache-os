import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Records the live voice session to a media file on disk, independently of
/// the realtime transcription stream.
///
/// Two modes:
/// - `.audioOnly` → `.m4a` (AAC, 48 kHz stereo) with the mic and, when
///   requested, system audio mixed in.
/// - `.window(_)` → `.mov` (H.264 + AAC) that additionally captures the
///   attached window via ScreenCaptureKit.
///
/// Crash safety: the writer emits QuickTime movie fragments every
/// `Configuration.fragmentInterval` seconds, so if the machine dies (battery,
/// kernel panic, force-quit) the file on disk stays playable up to the last
/// fragment instead of being an unreadable stub with no `moov` atom.
///
/// Reliability of the window source: the captured window can disappear at
/// any moment (the call ends, the user closes it). Two independent signals
/// feed `onSourceLost`: the SCStream delegate's stop callback *and* a 2 s
/// watchdog that checks the window still exists via `CGWindowListCopyWindowInfo`.
/// Whichever fires first finalises the file cleanly.
final class VoiceMediaRecorder: NSObject {

    enum Mode: Equatable {
        case audioOnly
        case window(CapturableWindow)

        var isVideo: Bool {
            if case .window = self { return true }
            return false
        }

        var window: CapturableWindow? {
            if case .window(let w) = self { return w }
            return nil
        }
    }

    struct Configuration {
        var mode: Mode
        var includeSystemAudio: Bool
        var micDeviceUID: String?
        var outputDirectory: URL
        /// Seconds between movie fragments (crash-safety flush cadence).
        var fragmentInterval: TimeInterval = 10
        /// Longest edge of the captured video, in pixels.
        var maxVideoLongEdge: Int = 1920
        var frameRate: Int = 15
        var startedAt: Date = Date()
    }

    struct Result: Equatable {
        let url: URL
        let duration: TimeInterval
        let mode: Mode
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case microphonePermissionDenied
        case screenRecordingPermissionDenied
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A media recording is already in progress."
            case .microphonePermissionDenied:
                return "Microphone access denied."
            case .screenRecordingPermissionDenied:
                return "Screen Recording permission is required to save system audio or a window video. Enable BrainCache in System Settings, then quit and reopen the app."
            case .writerFailed(let message):
                return "Could not start the media recording: \(message)"
            }
        }
    }

    // MARK: - Public state

    private(set) var isRecording = false
    private(set) var outputURL: URL?
    private(set) var startedAt: Date?
    private(set) var mode: Mode = .audioOnly
    private(set) var includesSystemAudio = false

    /// Fires on the main queue after the attached window disappeared (closed,
    /// or its capture stream was torn down by the system). The recording has
    /// already been finalised by the time this fires; `stop` is a no-op.
    var onSourceLost: ((CapturableWindow, Result?) -> Void)?
    /// Fires on the main queue when the asset writer fails irrecoverably
    /// mid-recording (disk full, file deleted). The recording is stopped
    /// before this fires; the result carries whatever fragments made it to
    /// disk, or `nil` when nothing usable was written.
    var onWriterFailure: ((Error, Result?) -> Void)?

    // MARK: - Internals

    private let writerQueue = DispatchQueue(
        label: "com.braincache.voice-media-writer",
        qos: .userInitiated
    )

    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var videoInput: AVAssetWriterInput?
    /// True between `startWriting()` and the finalisation block; appends
    /// check this on `writerQueue` so nothing is written after
    /// `markAsFinished`.
    private var acceptingSamples = false
    private var sessionStartPTS: CMTime?
    private var audioAnchorPTS: CMTime?
    private var audioFramesWritten: Int64 = 0
    private var audioFormatDescription: CMAudioFormatDescription?
    private var lastVideoPTS: CMTime = .invalid
    private var lastVideoSample: CMSampleBuffer?
    private var videoHeartbeat: DispatchSourceTimer?
    private var stopCompletion: ((Result?) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var videoStream: SCStream?
    private var systemAudioStream: SCStream?
    private var systemAudioGeneration = 0
    private var windowWatchdog: DispatchSourceTimer?

    private let outputSampleRate: Double = 48_000
    private let outputChannels: AVAudioChannelCount = 2
    private lazy var mixFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: outputChannels,
        interleaved: true
    )!

    private var systemRing = StereoRingBuffer(capacity: 48_000 * 4)
    private let ringLock = NSLock()

    // MARK: - Pure helpers (unit-tested)

    /// Output file name for a recording that started at `date`. Audio-only
    /// recordings are `.m4a`; window recordings are `.mov` and carry the app
    /// name so a folder full of recordings stays scannable.
    static func fileName(startedAt date: Date, mode: Mode) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = fmt.string(from: date)
        switch mode {
        case .audioOnly:
            return "Voice \(stamp).m4a"
        case .window(let window):
            let app = sanitizedFileComponent(window.appName)
            return app.isEmpty ? "Voice \(stamp).mov" : "Voice \(stamp) - \(app).mov"
        }
    }

    static func sanitizedFileComponent(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw.unicodeScalars
            .map { forbidden.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
        let collapsed = cleaned
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(40))
    }

    /// Video dimensions for a window of `size` points: scaled so the longer
    /// edge is at most `maxLongEdge`, rounded down to even numbers (H.264
    /// requires even dimensions), never below 2×2.
    static func videoDimensions(forWindowSize size: CGSize, maxLongEdge: Int) -> (width: Int, height: Int) {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let longEdge = max(w, h)
        let scale = min(1.0, Double(maxLongEdge) / Double(longEdge))
        func even(_ v: Double) -> Int {
            let i = Int(v.rounded(.down))
            return max(2, i - (i % 2))
        }
        return (even(w * scale), even(h * scale))
    }

    /// Target H.264 bitrate: ~0.1 bit per pixel per frame, clamped to a
    /// sensible 1–8 Mbps range. Screen content compresses well so this
    /// stays crisp for text while keeping hour-long meetings manageable.
    static func videoBitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let raw = Double(width * height * max(frameRate, 1)) * 0.1
        return Int(min(8_000_000, max(1_000_000, raw)))
    }

    /// Whether a window with the given CoreGraphics ID still exists.
    static func windowExists(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]] else {
            return false
        }
        return !list.isEmpty
    }

    // MARK: - Start

    /// Starts the recording and returns the file URL. Throws when permissions
    /// are missing or the writer cannot be created; nothing is left on disk
    /// in that case.
    @discardableResult
    func start(configuration: Configuration) throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphonePermissionDenied
        }
        if configuration.mode.isVideo || configuration.includeSystemAudio {
            guard AccessibilityChecker.isScreenRecordingGranted else {
                throw RecorderError.screenRecordingPermissionDenied
            }
        }

        try FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true
        )
        let fileName = Self.fileName(startedAt: configuration.startedAt, mode: configuration.mode)
        let url = configuration.outputDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        let fileType: AVFileType = configuration.mode.isVideo ? .mov : .m4a
        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }
        assetWriter.movieFragmentInterval = CMTime(
            seconds: max(1, configuration.fragmentInterval),
            preferredTimescale: 600
        )
        assetWriter.shouldOptimizeForNetworkUse = false

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: Int(outputChannels),
            AVEncoderBitRateKey: 128_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(audio) else {
            throw RecorderError.writerFailed("audio track rejected")
        }
        assetWriter.add(audio)

        var video: AVAssetWriterInput?
        if case .window(let window) = configuration.mode {
            let dims = Self.videoDimensions(
                forWindowSize: window.frame.size,
                maxLongEdge: configuration.maxVideoLongEdge
            )
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dims.width,
                AVVideoHeightKey: dims.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.videoBitrate(
                        width: dims.width, height: dims.height, frameRate: configuration.frameRate
                    ),
                    AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else {
                throw RecorderError.writerFailed("video track rejected")
            }
            assetWriter.add(input)
            video = input
        }

        guard assetWriter.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "unknown")
        }

        writer = assetWriter
        audioInput = audio
        videoInput = video
        outputURL = url
        startedAt = configuration.startedAt
        mode = configuration.mode
        includesSystemAudio = configuration.includeSystemAudio
        sessionStartPTS = nil
        audioAnchorPTS = nil
        audioFramesWritten = 0
        lastVideoPTS = .invalid
        lastVideoSample = nil
        audioFormatDescription = Self.makeAudioFormatDescription(
            sampleRate: outputSampleRate, channels: outputChannels
        )
        ringLock.lock()
        systemRing.reset()
        ringLock.unlock()
        writerQueue.sync { acceptingSamples = true }
        isRecording = true

        do {
            try startMicCapture(deviceUID: configuration.micDeviceUID)
        } catch {
            abandonWriter(removeFile: true)
            throw error
        }

        if case .window(let window) = configuration.mode {
            startWindowCapture(window: window, configuration: configuration)
            startWindowWatchdog(window: window)
            startVideoHeartbeat()
        }
        if configuration.includeSystemAudio {
            startSystemAudioCapture()
        }
        NSLog("VoiceMediaRecorder: started %@ → %@", configuration.mode.isVideo ? "window video" : "audio", url.path)
        return url
    }

    // MARK: - Stop

    /// Finalises the file. `completion` is called on the main queue with the
    /// result, or `nil` when the recording was too short / never received
    /// any media (the empty file is removed). Safe to call repeatedly.
    func stop(completion: ((Result?) -> Void)? = nil) {
        guard isRecording else {
            DispatchQueue.main.async { completion?(nil) }
            return
        }
        isRecording = false
        stopWindowWatchdog()
        stopVideoHeartbeat()
        stopMicCapture()
        stopWindowCapture()
        stopSystemAudioCapture()

        let url = outputURL
        let started = startedAt
        let currentMode = mode
        let duration = started.map { Date().timeIntervalSince($0) } ?? 0

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.acceptingSamples = false
            guard let writer = self.writer else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            let hadSession = self.sessionStartPTS != nil
            self.audioInput?.markAsFinished()
            self.videoInput?.markAsFinished()
            self.writer = nil
            self.audioInput = nil
            self.videoInput = nil
            self.lastVideoSample = nil

            let finish: (Bool) -> Void = { succeeded in
                DispatchQueue.main.async { [weak self] in
                    self?.outputURL = nil
                    self?.startedAt = nil
                    guard succeeded, let url, duration >= 1.0 else {
                        if let url { try? FileManager.default.removeItem(at: url) }
                        completion?(nil)
                        return
                    }
                    completion?(Result(url: url, duration: duration, mode: currentMode))
                }
            }

            guard hadSession, writer.status == .writing else {
                writer.cancelWriting()
                finish(false)
                return
            }
            writer.finishWriting {
                if writer.status == .completed {
                    finish(true)
                } else {
                    NSLog("VoiceMediaRecorder: finishWriting ended with status %ld: %@",
                          writer.status.rawValue, writer.error?.localizedDescription ?? "-")
                    // A fragmented file is still usable up to the last
                    // fragment even when finalisation fails — keep it.
                    finish(url != nil && FileManager.default.fileExists(atPath: url?.path ?? ""))
                }
            }
        }
    }

    private func abandonWriter(removeFile: Bool) {
        isRecording = false
        stopWindowWatchdog()
        stopVideoHeartbeat()
        stopMicCapture()
        stopWindowCapture()
        stopSystemAudioCapture()
        let url = outputURL
        writerQueue.sync {
            acceptingSamples = false
            writer?.cancelWriting()
            writer = nil
            audioInput = nil
            videoInput = nil
            lastVideoSample = nil
        }
        if removeFile, let url { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
        startedAt = nil
    }

    // MARK: - System audio toggling mid-recording

    /// Starts / stops mixing system audio into the file while recording, so
    /// the file follows the panel's Sys toggle instead of freezing whatever
    /// state it had at start.
    func setIncludesSystemAudio(_ enabled: Bool) {
        guard isRecording, enabled != includesSystemAudio else { return }
        guard !enabled || AccessibilityChecker.isScreenRecordingGranted else { return }
        includesSystemAudio = enabled
        if enabled {
            startSystemAudioCapture()
        } else {
            stopSystemAudioCapture()
        }
    }

    // MARK: - Mic capture

    private func startMicCapture(deviceUID: String?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let uid = deviceUID {
            VoiceTranscriptionRecorder.setInputDevice(on: engine, uid: uid)
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.writerFailed("no microphone input format")
        }
        // The writer path assumes 48 kHz interleaved stereo float. Refuse to
        // start rather than feed it a mismatched layout if the converter
        // can't be built for this device's native format.
        guard let converter = AVAudioConverter(from: inputFormat, to: mixFormat) else {
            throw RecorderError.writerFailed("unsupported microphone format \(inputFormat)")
        }
        micConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.handleMicBuffer(buffer, when: when)
        }
        try engine.start()
        audioEngine = engine
    }

    private func stopMicCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micConverter = nil
    }

    private func handleMicBuffer(_ micBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard isRecording, micBuffer.frameLength > 0 else { return }

        guard let converter = micConverter else { return }
        let ratio = outputSampleRate / micBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(micBuffer.frameLength) * ratio) + 64
        guard let mixed = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: mixed, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return micBuffer
        }
        guard status != .error, error == nil, mixed.frameLength > 0 else { return }

        // Mix in whatever system audio arrived since the last mic buffer.
        if includesSystemAudio, let data = mixed.floatChannelData?[0] {
            let frames = Int(mixed.frameLength)
            ringLock.lock()
            systemRing.mixInto(interleaved: data, frameCount: frames)
            ringLock.unlock()
        }

        let hostTime = when.isHostTimeValid ? when.hostTime : 0
        writerQueue.async { [weak self] in
            self?.appendAudio(mixed, hostTime: hostTime)
        }
    }

    // MARK: - Writer appends (writerQueue)

    private func ensureSessionStarted(at pts: CMTime, writer: AVAssetWriter) {
        guard sessionStartPTS == nil else { return }
        writer.startSession(atSourceTime: pts)
        sessionStartPTS = pts
    }

    private func appendAudio(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard acceptingSamples, let writer, writer.status == .writing,
              let audioInput, let formatDescription = audioFormatDescription else { return }

        if audioAnchorPTS == nil {
            audioAnchorPTS = hostTime > 0
                ? CMClockMakeHostTimeFromSystemUnits(hostTime)
                : CMClockGetTime(CMClockGetHostTimeClock())
        }
        guard let anchor = audioAnchorPTS else { return }
        let pts = CMTimeAdd(anchor, CMTime(value: audioFramesWritten, timescale: CMTimeScale(outputSampleRate)))
        ensureSessionStarted(at: pts, writer: writer)
        guard let sessionStart = sessionStartPTS, CMTimeCompare(pts, sessionStart) >= 0 else { return }

        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData?[0] else { return }
        let bytesPerFrame = Int(outputChannels) * MemoryLayout<Float>.size
        let byteCount = frames * bytesPerFrame

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return }
        guard CMBlockBufferReplaceDataBytes(
            with: UnsafeRawPointer(data), blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
        ) == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(outputSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        // Real-time input: dropping a buffer when the encoder is briefly
        // behind is better than blocking the audio thread's dispatch chain.
        // The timeline still advances so later audio stays in sync with the
        // video track instead of sliding earlier by one buffer per drop.
        guard audioInput.isReadyForMoreMediaData else {
            audioFramesWritten += Int64(frames)
            return
        }
        if audioInput.append(sample) {
            audioFramesWritten += Int64(frames)
        } else {
            handleWriterFailure(writer)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, let writer, writer.status == .writing, let videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        ensureSessionStarted(at: pts, writer: writer)
        guard let sessionStart = sessionStartPTS, CMTimeCompare(pts, sessionStart) >= 0 else { return }
        if lastVideoPTS.isValid, CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            lastVideoPTS = pts
            lastVideoSample = sampleBuffer
        } else {
            handleWriterFailure(writer)
        }
    }

    /// ScreenCaptureKit only delivers frames when the window content changes,
    /// so a static window would leave the video track far shorter than the
    /// audio. Re-append the last frame once per second of silence so the
    /// track (and every crash-safety fragment) stays continuous.
    private func startVideoHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.acceptingSamples, let last = self.lastVideoSample else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            guard self.lastVideoPTS.isValid,
                  CMTimeGetSeconds(CMTimeSubtract(now, self.lastVideoPTS)) >= 1 else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: last,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy
            ) == noErr, let copy else { return }
            self.appendVideo(copy)
        }
        timer.resume()
        videoHeartbeat = timer
    }

    private func stopVideoHeartbeat() {
        videoHeartbeat?.cancel()
        videoHeartbeat = nil
    }

    private func handleWriterFailure(_ writer: AVAssetWriter) {
        guard acceptingSamples else { return }
        acceptingSamples = false
        let error = writer.error ?? RecorderError.writerFailed("append failed")
        NSLog("VoiceMediaRecorder: writer failed: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.stop { result in
                self.onWriterFailure?(error, result)
            }
        }
    }

    private static func makeAudioFormatDescription(
        sampleRate: Double, channels: AVAudioChannelCount
    ) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        )
        return description
    }

    // MARK: - Window video capture (ScreenCaptureKit)

    private func startWindowCapture(window: CapturableWindow, configuration: Configuration) {
        let dims = Self.videoDimensions(
            forWindowSize: window.frame.size,
            maxLongEdge: configuration.maxVideoLongEdge
        )
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self else { return }
                guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                    NSLog("VoiceMediaRecorder: attached window %u no longer exists", window.id)
                    self.handleSourceLost(window)
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.width = dims.width
                config.height = dims.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.queueDepth = 5
                config.capturesAudio = false
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, configuration.frameRate)))

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.writerQueue)
                try await stream.startCapture()
                guard self.isRecording else {
                    try? await stream.stopCapture()
                    return
                }
                self.videoStream = stream
            } catch {
                NSLog("VoiceMediaRecorder: window capture failed: %@", error.localizedDescription)
                self?.handleSourceLost(window)
            }
        }
    }

    private func stopWindowCapture() {
        guard let stream = videoStream else { return }
        videoStream = nil
        Task { try? await stream.stopCapture() }
    }

    private func startWindowWatchdog(window: CapturableWindow) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            if !Self.windowExists(window.id) {
                NSLog("VoiceMediaRecorder: watchdog — attached window %u disappeared", window.id)
                self.handleSourceLost(window)
            }
        }
        timer.resume()
        windowWatchdog = timer
    }

    private func stopWindowWatchdog() {
        windowWatchdog?.cancel()
        windowWatchdog = nil
    }

    /// Single funnel for "the window is gone" from any signal. Finalises the
    /// file first so the user never loses what was captured, then reports.
    private func handleSourceLost(_ window: CapturableWindow) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.mode == .window(window) else { return }
            self.stop { [weak self] result in
                self?.onSourceLost?(window, result)
            }
        }
    }

    // MARK: - System audio capture (ScreenCaptureKit, display-wide)

    private func startSystemAudioCapture() {
        systemAudioGeneration += 1
        let generation = systemAudioGeneration
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(self.outputSampleRate)
                config.channelCount = Int(self.outputChannels)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
                try await stream.startCapture()
                guard self.isRecording, self.includesSystemAudio, self.systemAudioGeneration == generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.systemAudioStream = stream
            } catch {
                NSLog("VoiceMediaRecorder: system audio capture failed: %@", error.localizedDescription)
            }
        }
    }

    private func stopSystemAudioCapture() {
        systemAudioGeneration += 1
        guard let stream = systemAudioStream else { return }
        systemAudioStream = nil
        Task { try? await stream.stopCapture() }
        ringLock.lock()
        systemRing.reset()
        ringLock.unlock()
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let floatPtr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)

        ringLock.lock()
        if isNonInterleaved {
            let ch0 = floatPtr
            let ch1 = channels > 1 ? floatPtr.advanced(by: frameCount) : ch0
            for frame in 0..<frameCount {
                systemRing.write(left: ch0[frame], right: ch1[frame])
            }
        } else {
            for frame in 0..<frameCount {
                let base = frame * channels
                let left = floatPtr[base]
                let right = channels > 1 ? floatPtr[base + 1] : left
                systemRing.write(left: left, right: right)
            }
        }
        ringLock.unlock()
    }
}

// MARK: - SCStreamOutput

extension VoiceMediaRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording else { return }
        switch type {
        case .audio:
            guard includesSystemAudio else { return }
            handleSystemAudioSample(sampleBuffer)
        case .screen:
            // Only complete frames carry a fresh image; idle/blank frames
            // are heartbeats with nothing new to encode.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let frameStatus = SCFrameStatus(rawValue: statusRaw),
                  frameStatus == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            appendVideo(sampleBuffer)
        default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension VoiceMediaRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("VoiceMediaRecorder: SCStream stopped: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if stream === self.videoStream {
                self.videoStream = nil
                if let window = self.mode.window { self.handleSourceLost(window) }
            } else if stream === self.systemAudioStream {
                // Losing system audio is not fatal — the mic keeps writing.
                self.systemAudioStream = nil
            }
        }
    }
}

// MARK: - Stereo ring buffer for system audio

/// Single-producer / single-consumer stereo float ring used to line the
/// asynchronously-arriving system audio up with mic buffers. Guarded by the
/// recorder's `ringLock`.
struct StereoRingBuffer {
    private var left: [Float]
    private var right: [Float]
    private var writePos = 0
    private var readPos = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        left = [Float](repeating: 0, count: self.capacity)
        right = [Float](repeating: 0, count: self.capacity)
    }

    mutating func reset() {
        writePos = 0
        readPos = 0
        count = 0
    }

    mutating func write(left l: Float, right r: Float) {
        left[writePos] = l
        right[writePos] = r
        writePos = (writePos + 1) % capacity
        if count < capacity {
            count += 1
        } else {
            readPos = (readPos + 1) % capacity
        }
    }

    /// Adds up to `frameCount` frames into an interleaved stereo buffer.
    /// Returns the number of frames mixed.
    @discardableResult
    mutating func mixInto(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let toRead = min(frameCount, count)
        for i in 0..<toRead {
            let pos = (readPos + i) % capacity
            interleaved[i * 2] += left[pos]
            interleaved[i * 2 + 1] += right[pos]
        }
        readPos = (readPos + toRead) % capacity
        count -= toRead
        return toRead
    }
}
