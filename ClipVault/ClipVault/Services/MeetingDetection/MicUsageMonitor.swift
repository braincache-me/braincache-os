import CoreAudio
import Foundation

/// A process that currently holds an active microphone input stream.
/// Deliberately outside `MicUsageMonitor` so macOS 13 code (which can never
/// receive one) can still name the type.
struct MicAudioProcess: Hashable {
    let pid: pid_t
    let bundleID: String
}

/// Watches which other processes are actively capturing microphone audio,
/// using the CoreAudio HAL process objects introduced in macOS 14
/// (`kAudioHardwarePropertyProcessObjectList` + per-process
/// `kAudioProcessPropertyIsRunningInput`). Reading this metadata needs no TCC
/// permission — only *capturing* audio does.
///
/// Change delivery combines a property listener on the process-object list
/// with a slow poll: the list listener fires when HAL clients come and go, but
/// per-process IsRunningInput listeners are unreliable on macOS 15
/// (FB-reported), so the poll is the belt-and-braces that catches an existing
/// client toggling its input stream.
@available(macOS 14.0, *)
final class MicUsageMonitor {

    /// Called on `queue` whenever the set of external processes with an active
    /// input stream changes (own process already excluded).
    var onChange: (([MicAudioProcess]) -> Void)?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var lastReported: Set<MicAudioProcess>?
    private let pollInterval: TimeInterval

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(queue: DispatchQueue = DispatchQueue(label: "com.clipvault.mic-usage-monitor"),
         pollInterval: TimeInterval = 2.0) {
        self.queue = queue
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    func start() {
        guard timer == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.check() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &processListAddress,
            queue,
            block
        )

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &processListAddress,
                queue,
                block
            )
            listenerBlock = nil
        }
        lastReported = nil
    }

    // MARK: - Enumeration

    private func check() {
        let active = Set(activeInputProcesses())
        guard active != lastReported else { return }
        lastReported = active
        onChange?(Array(active))
    }

    /// All processes (except our own) that currently have an active input
    /// (microphone) stream.
    private func activeInputProcesses() -> [MicAudioProcess] {
        let ownPID = getpid()
        return processObjectIDs().compactMap { objectID in
            guard readUInt32(objectID, selector: kAudioProcessPropertyIsRunningInput) == 1 else {
                return nil
            }
            guard let pid = readPID(objectID), pid != ownPID else { return nil }
            let bundleID = readBundleID(objectID) ?? ""
            return MicAudioProcess(pid: pid, bundleID: bundleID)
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = processListAddress
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private func readUInt32(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    private func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, value >= 0 else { return nil }
        return value
    }

    private func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}
