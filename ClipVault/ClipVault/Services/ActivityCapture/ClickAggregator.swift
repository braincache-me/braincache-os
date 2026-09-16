import Foundation

/// Buffers consecutive clicks on the same control and emits a single coalesced event.
///
/// Clicks are considered "the same" when they share `eventType`, `bundleID`,
/// `windowTitle`, `controlRole`, and `controlName`. While a burst is in progress
/// the first click's metadata (coordinates, OCR text, URL) is preserved — only
/// `triggerMetadata` is rewritten to `"count=N"` on flush when N > 1.
///
/// Flushes occur when:
/// - The next click has a different control context
/// - `flush()` is called explicitly (key event, focus change, pause/stop)
/// - The debounce timer fires after the last click in a burst
///
/// All calls must come from the main thread (the coordinator dispatches there).
final class ClickAggregator {

    /// Called when a coalesced click event is ready to emit.
    var onFlush: ((ActivityEvent) -> Void)?

    /// Seconds of inactivity before a buffered burst is emitted.
    let debounceInterval: TimeInterval

    private var pending: ActivityEvent?
    private var count: Int = 0
    private var flushTimer: DispatchWorkItem?

    init(debounceInterval: TimeInterval = 1.5) {
        self.debounceInterval = debounceInterval
    }

    /// Append a click event. Emits an earlier burst if the context changed.
    func append(_ event: ActivityEvent) {
        if let current = pending, Self.isSameControl(current, event) {
            count += 1
            restartTimer()
            return
        }

        flush()
        pending = event
        count = 1
        restartTimer()
    }

    /// Emit any buffered burst immediately and clear state.
    func flush() {
        flushTimer?.cancel()
        flushTimer = nil

        guard let event = pending else { return }
        let toEmit: ActivityEvent
        if count > 1 {
            toEmit = ActivityEvent(
                id: event.id,
                timestamp: event.timestamp,
                appName: event.appName,
                bundleID: event.bundleID,
                windowTitle: event.windowTitle,
                eventType: event.eventType,
                controlRole: event.controlRole,
                controlName: event.controlName,
                controlValue: event.controlValue,
                clickX: event.clickX,
                clickY: event.clickY,
                windowClickX: event.windowClickX,
                windowClickY: event.windowClickY,
                nearbyText: event.nearbyText,
                url: event.url,
                screenshotPath: event.screenshotPath,
                audioPath: event.audioPath,
                transcriptPath: event.transcriptPath,
                windowIdentifier: event.windowIdentifier,
                triggerMetadata: "count=\(count)"
            )
        } else {
            toEmit = event
        }

        pending = nil
        count = 0
        onFlush?(toEmit)
    }

    // MARK: - Private

    private static func isSameControl(_ a: ActivityEvent, _ b: ActivityEvent) -> Bool {
        a.eventType == b.eventType &&
        a.bundleID == b.bundleID &&
        a.windowTitle == b.windowTitle &&
        a.controlRole == b.controlRole &&
        a.controlName == b.controlName
    }

    private func restartTimer() {
        flushTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
