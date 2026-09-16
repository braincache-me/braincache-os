import AppKit
import Foundation

protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry)
}

final class ClipboardMonitor {

    weak var delegate: ClipboardMonitorDelegate?

    private let reader: PasteboardReader
    private let pasteboard: PasteboardProtocol
    private let settings: Settings
    /// Override for testing — if non-nil, replaces AppDetector lookup for current frontmost app.
    var sourceAppProvider: (() -> String?)?
    /// Override for testing — if non-nil, replaces AppDetector lookup for the app-switch history.
    var switchHistoryProvider: (() -> [AppDetector.AppSwitchEvent])?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.yourname.ClipVault.ClipboardMonitor", qos: .utility)
    private var lastChangeCount: Int = -1
    private var lastHash: String = ""

    // Transient clipboard debounce — emit after 100ms of stability
    private var pendingEntry: ClipboardEntry?
    private var pendingWorkItem: DispatchWorkItem?

    // Sleep/wake suspend tracking
    private var isSuspended = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private(set) var isRunning = false

    init(
        pasteboard: PasteboardProtocol = NSPasteboard.general,
        reader: PasteboardReader = PasteboardReader(),
        settings: Settings = .shared
    ) {
        self.pasteboard = pasteboard
        self.reader = reader
        self.settings = settings
    }

    /// Determines which app produced the clipboard content at changeCount `currentCount` by
    /// walking the switch history newest-first. Returns the incomingBundleID of the first
    /// switch whose changeCountAtSwitch is strictly less than currentCount (meaning the copy
    /// happened while that app was active). If all recorded switches show changeCountAtSwitch
    /// >= currentCount the copy predates the history window; falls back to the outgoingBundleID
    /// of the oldest entry. Returns nil when history is empty.
    private func resolvedSource(currentCount: Int, in history: [AppDetector.AppSwitchEvent]) -> String? {
        for event in history.reversed() {
            if currentCount > event.changeCountAtSwitch {
                return event.incomingBundleID
            }
        }
        return history.first?.outgoingBundleID
    }

    /// Returns true if the given bundle ID is in the excluded list.
    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return settings.excludedBundleIDs.contains(bundleID)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Seed lastChangeCount with the current value so the very first poll sees no
        // change and skips whatever was already on the clipboard before ClipVault started.
        // Without this, a clip copied from an excluded app before launch could slip through
        // if the user switched to a non-excluded app before ClipVault began monitoring.
        lastChangeCount = pasteboard.changeCount

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        source.resume()
        timer = source

        // Register sleep/wake observers to suspend/resume the timer
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.suspendTimer() }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.resumeTimer() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        // Dispatch synchronously onto the timer's queue so all mutations of pendingWorkItem,
        // pendingEntry, and the timer are serialised with poll() and suspendTimer()/resumeTimer().
        queue.sync {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            pendingEntry = nil
            if isSuspended {
                timer?.resume()
                isSuspended = false
            }
            timer?.cancel()
            timer = nil
        }

        if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObserver = nil
        wakeObserver = nil
    }

    // MARK: - Sleep / Wake

    func suspendTimer() {
        queue.async { [weak self] in
            guard let self, !self.isSuspended, self.timer != nil else { return }
            self.isSuspended = true
            self.timer?.suspend()
        }
    }

    func resumeTimer() {
        queue.async { [weak self] in
            guard let self, self.isSuspended, self.timer != nil else { return }
            self.isSuspended = false
            self.timer?.resume()
        }
    }

    /// Pre-sets lastHash so the monitor skips the next clipboard write whose content
    /// matches `hash`. Call this before writing a clip back to the pasteboard via
    /// PasteService to avoid re-inserting a pasted history item as a new duplicate entry.
    func suppressNextCapture(hash: String) {
        queue.async { [weak self] in
            self?.lastHash = hash
        }
    }

    // MARK: - Polling

    private func poll() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Resolve the app that produced the clipboard change. Walk switch history first so
        // a poll that fires after a fast app switch uses the true source, not whatever is
        // frontmost at poll time. Falls back to the live frontmost app when history is empty.
        // Using a single resolved value for both the exclusion check and entry attribution
        // ensures the stored sourceApp matches the actual copy source.
        let history = switchHistoryProvider?() ?? AppDetector.shared.switchHistorySnapshot()
        let liveApp = sourceAppProvider?() ?? AppDetector.shared.currentFrontmostBundleID
        let sourceApp = resolvedSource(currentCount: currentCount, in: history) ?? liveApp

        // Skip entries from excluded applications.
        guard !isExcluded(bundleID: sourceApp) else { return }

        guard let entry = reader.read(from: pasteboard, sourceApp: sourceApp) else { return }

        // Skip if this hash was already emitted or is already pending
        guard entry.dataHash != lastHash else { return }
        guard entry.dataHash != pendingEntry?.dataHash else { return }

        // Cancel any previously pending emission (transient clipboard debounce)
        pendingWorkItem?.cancel()
        pendingEntry = entry

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingEntry else { return }
            self.lastHash = pending.dataHash
            self.pendingEntry = nil
            self.pendingWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.clipboardMonitor(self, didCapture: pending)
            }
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }
}
