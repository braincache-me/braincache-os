import AppKit
import Carbon.HIToolbox

/// Detects the writing assistant's global double-tap right Command gesture.
final class WritingAssistantHotkeyMonitor {

    var doubleTapHandler: (() -> Void)?

    private let doubleTapInterval: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightCommandDown = false
    private var lastTapTimestamp: TimeInterval = 0

    init(doubleTapInterval: TimeInterval = 0.45) {
        self.doubleTapInterval = doubleTapInterval
    }

    deinit {
        stop()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_RightCommand) else { return }

        let isDown = event.modifierFlags.contains(.command)
        if isDown {
            rightCommandDown = true
            return
        }

        guard rightCommandDown else { return }
        rightCommandDown = false

        let timestamp = event.timestamp
        if timestamp - lastTapTimestamp <= doubleTapInterval {
            lastTapTimestamp = 0
            doubleTapHandler?()
        } else {
            lastTapTimestamp = timestamp
        }
    }
}
