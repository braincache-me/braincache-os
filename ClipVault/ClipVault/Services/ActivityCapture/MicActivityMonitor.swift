import Foundation
import CoreAudio
import AudioToolbox
import Darwin
import os

protocol MicActivityMonitoring: AnyObject {
    var onMicBecameActive: (() -> Void)? { get set }
    var onMicBecameInactive: (() -> Void)? { get set }
    var isMicActive: Bool { get }
    /// Seconds to wait after the mic stops running before reporting it inactive.
    /// Acts as a debounce so a brief release/reopen (e.g. an app reacquiring the
    /// mic on mute toggle) doesn't fire `onMicBecameInactive`.
    var silenceDebounceSeconds: TimeInterval { get set }
    func start()
    func stop()
}

/// Tracks whether *another* process is currently using the microphone.
///
/// The system-wide `kAudioDevicePropertyDeviceIsRunningSomewhere` flag stays
/// at 1 as long as *any* process — including ours — has the input device open.
/// Once `MeetingTranscriptRecorder` or `MeetingAudioRecorder` start, they hold
/// the mic too, so that flag becomes useless for detecting the meeting app
/// releasing the mic. We use the per-process audio API instead
/// (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyPID` +
/// `kAudioProcessPropertyIsRunningInput`) and skip our own PID, then poll the
/// state on a 1.5 s cadence — there is no notification API that fires when an
/// individual process's input-running flag flips without the system-wide
/// device-running bit also flipping.
final class MicActivityMonitor: MicActivityMonitoring {

    var onMicBecameActive: (() -> Void)?
    var onMicBecameInactive: (() -> Void)?

    private(set) var isMicActive: Bool = false

    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var debounceTimer: DispatchWorkItem?
    private var pollingTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.braincache.mic-activity-monitor", qos: .userInitiated)
    private var isStarted = false

    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    var silenceDebounceSeconds: TimeInterval = 5.0
    /// Polling cadence for the external-process check. Tight enough to feel
    /// responsive when a meeting starts/ends, loose enough to be negligible
    /// load (a CoreAudio property fetch every couple of seconds).
    private let pollingInterval: TimeInterval = 1.5

    private static let logger = Logger(subsystem: "com.braincache.activity", category: "mic-monitor")

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Private

    private func startOnQueue() {
        guard !isStarted else { return }
        isStarted = true

        currentDeviceID = Self.defaultInputDevice()
        addDefaultDeviceChangeListener()

        // Evaluate immediately so an already-running meeting app is picked up
        // on the first tick rather than waiting for the poll interval.
        evaluateExternalMicState()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + pollingInterval,
            repeating: pollingInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateExternalMicState()
        }
        timer.resume()
        pollingTimer = timer
        Self.logger.log("started (ownPID=\(self.ownPID, privacy: .public), poll=\(self.pollingInterval, privacy: .public)s, release-delay=\(Int(self.silenceDebounceSeconds), privacy: .public)s)")
    }

    private func stopOnQueue() {
        guard isStarted else { return }
        isStarted = false
        debounceTimer?.cancel()
        debounceTimer = nil
        pollingTimer?.cancel()
        pollingTimer = nil

        removeDefaultDeviceChangeListener()
        isMicActive = false
        Self.logger.log("stopped")
    }

    /// Decides whether the mic should be considered active based on whether
    /// any process *other than us* currently has the input device running.
    /// Drives both the "became active" and "became inactive" transitions.
    private func evaluateExternalMicState() {
        guard isStarted else { return }
        let externalActive = Self.isExternalProcessUsingMicInput(ownPID: ownPID)

        if externalActive {
            if !isMicActive {
                debounceTimer?.cancel()
                debounceTimer = nil
                isMicActive = true
                Self.logger.log("→ external process opened mic")
                DispatchQueue.main.async { [weak self] in
                    self?.onMicBecameActive?()
                }
            } else if debounceTimer != nil {
                // External resumed during the post-release debounce window —
                // cancel the pending "inactive" callback so a brief blip in
                // the middle of a meeting doesn't end the recording.
                debounceTimer?.cancel()
                debounceTimer = nil
                Self.logger.log("debounce cancelled — external resumed")
            }
        } else if isMicActive && debounceTimer == nil {
            Self.logger.log("→ external released mic, starting \(Int(self.silenceDebounceSeconds), privacy: .public)s debounce")
            startDebounceForInactive()
        }
    }

    // MARK: - CoreAudio listeners

    private func addDefaultDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, defaultDeviceChanged, selfPtr)
    }

    private func removeDefaultDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, defaultDeviceChanged, selfPtr)
    }

    // MARK: - Callbacks

    fileprivate func handleDefaultDeviceChanged() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.currentDeviceID = Self.defaultInputDevice()
            // Re-evaluate immediately on device change — the new input may or
            // may not be in use by an external app right now.
            self.evaluateExternalMicState()
        }
    }

    private func startDebounceForInactive() {
        debounceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            // Re-check at fire time in case external came back briefly and
            // the cancellation path was missed (timer-already-running races).
            let stillExternal = Self.isExternalProcessUsingMicInput(ownPID: self.ownPID)
            if !stillExternal {
                self.isMicActive = false
                Self.logger.log("→ external still gone after debounce, firing inactive")
                DispatchQueue.main.async { [weak self] in
                    self?.onMicBecameInactive?()
                }
            } else {
                Self.logger.log("debounce fired but external is back — staying active")
            }
            self.debounceTimer = nil
        }
        debounceTimer = work
        queue.asyncAfter(deadline: .now() + silenceDebounceSeconds, execute: work)
    }

    // MARK: - Static helpers

    static func defaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    /// Whether any process *other than the given PID* — and other than known
    /// system audio infrastructure — has audio input running.
    ///
    /// Uses the per-process audio API (`kAudioHardwarePropertyProcessObjectList`
    /// + `kAudioProcessPropertyPID` + `kAudioProcessPropertyIsRunningInput`).
    /// Filters out:
    ///   • our own process (the recorder's `AVAudioEngine` holds the mic),
    ///   • Apple audio helpers (`replayd`, `coreaudiod`, etc. — `ScreenCaptureKit`
    ///     opens an input stream via `replayd` in a separate PID whenever we
    ///     capture system audio, so a naive ownPID-only check stays "active"
    ///     for the whole recording).
    ///
    /// On macOS versions where the process-list API is unavailable, the first
    /// `AudioObjectGetPropertyDataSize` call returns a non-success status and
    /// the function returns `false` — i.e. we fail closed: the monitor simply
    /// won't fire active, which is preferable to firing forever.
    static func isExternalProcessUsingMicInput(ownPID: pid_t) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        var fetchedSize = size
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &fetchedSize, &processObjects
        ) == noErr else { return false }

        for proc in processObjects {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(proc, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }
            if pid == ownPID { continue }
            if isSystemAudioHelper(pid: pid) { continue }

            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isInput: UInt32 = 0
            var inSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(proc, &inAddr, 0, nil, &inSize, &isInput) == noErr else { continue }
            if isInput != 0 {
                return true
            }
        }
        return false
    }

    /// True for Apple audio infrastructure processes whose input usage is a
    /// side-effect of *our* capture (e.g. `replayd` started by our SCStream)
    /// rather than evidence of a real meeting app.
    ///
    /// Identified by executable path — Apple helpers live under `/System`,
    /// `/usr/libexec`, `/usr/sbin`, `/usr/bin`, `/sbin`, `/bin`. User-facing
    /// apps live elsewhere (`/Applications`, `~/Applications`, Homebrew, etc.),
    /// and a real meeting app like Zoom will never match these prefixes.
    private static func isSystemAudioHelper(pid: pid_t) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096. Hardcoded because
        // the constant lives in <sys/proc_info.h> which isn't bridged into Swift.
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard length > 0 else {
            // Path lookup failed — be conservative and don't suppress this PID.
            return false
        }
        let path = String(cString: pathBuf)
        return path.hasPrefix("/System/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/sbin/")
            || path.hasPrefix("/bin/")
    }

    /// Legacy helper kept for tests / callers that need the raw device-level flag.
    /// Note that this is `true` whenever *any* process — including ours — has the
    /// device open, which is why the monitor itself uses
    /// ``isExternalProcessUsingMicInput(ownPID:)`` instead.
    static func isDeviceRunning(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}

// MARK: - C callbacks

private func defaultDeviceChanged(
    _ objectID: AudioObjectID,
    _ numberOfAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let monitor = Unmanaged<MicActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleDefaultDeviceChanged()
    return noErr
}
