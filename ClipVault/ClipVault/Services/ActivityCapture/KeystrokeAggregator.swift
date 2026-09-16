import Foundation

/// Buffers individual keystrokes and emits consolidated text input events.
///
/// Characters typed in the same app/window context are merged into a single string.
/// A flush occurs when:
/// - The typing context changes (different app, window, or focused element)
/// - A timeout fires after the last keystroke (default 2 seconds)
/// - `flush()` is called explicitly (e.g. on pause/stop)
///
/// The aggregator runs entirely on the main thread — call it from the coordinator's
/// main-queue dispatch only.
final class KeystrokeAggregator {

    struct Context: Equatable {
        let appName: String
        let bundleID: String
        let windowTitle: String
    }

    /// Called when a consolidated text chunk is ready to emit.
    /// Parameters: (text, context, inputID).
    var onFlush: ((String, Context, UUID) -> Void)?

    private var buffer: String = ""
    private var currentContext: Context?
    private var flushTimer: DispatchWorkItem?
    private var inputSequenceID: UUID?

    /// Seconds of inactivity before the buffer is flushed.
    let debounceInterval: TimeInterval

    init(debounceInterval: TimeInterval = 2.0) {
        self.debounceInterval = debounceInterval
    }

    /// Append a character or string from a key event.
    /// If the context changed, the previous buffer is flushed first.
    func append(_ characters: String, context: Context) {
        if let current = currentContext, current != context {
            flush()
        }

        if currentContext == nil {
            currentContext = context
            inputSequenceID = UUID()
        }

        buffer.append(characters)
        restartTimer()
    }

    /// Force-flush any buffered text (e.g. on session pause/stop or context switch).
    func flush() {
        flushTimer?.cancel()
        flushTimer = nil

        guard !buffer.isEmpty, let ctx = currentContext, let seqID = inputSequenceID else {
            reset()
            return
        }

        let text = buffer
        onFlush?(text, ctx, seqID)
        reset()
    }

    /// The current input sequence ID (stable while typing in same context).
    var currentInputID: UUID? { inputSequenceID }

    /// Whether there is buffered text waiting to be flushed.
    var hasPendingText: Bool { !buffer.isEmpty }

    // MARK: - Private

    private func reset() {
        buffer = ""
        currentContext = nil
        inputSequenceID = nil
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
