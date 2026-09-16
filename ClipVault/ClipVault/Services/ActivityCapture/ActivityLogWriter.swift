import Foundation

/// Writes `ActivityEvent` values to daily JSONL log files.
///
/// Events are buffered and flushed either when the buffer reaches `flushThreshold` events,
/// when the flush timer fires every `flushInterval` seconds, or when `flush()` is called
/// explicitly. All file I/O runs on a private serial queue so the main thread is never blocked.
///
/// Day rotation is automatic: if the calendar day changes between events, a new log file is
/// opened and the old buffer is flushed first.
final class ActivityLogWriter {

    // MARK: - Configuration

    /// Number of events that trigger an immediate flush.
    let flushThreshold: Int

    /// Maximum seconds between automatic flushes.
    let flushInterval: TimeInterval

    // MARK: - Dependencies

    /// The `logs/` directory URL. Events are written to `<logsURL>/YYYY-MM-DD.jsonl`.
    private(set) var logsURL: URL?

    // MARK: - Private state

    private let queue = DispatchQueue(label: "com.TalkFlow.BrainCache.ActivityLogWriter", qos: .utility)
    private var buffer: [ActivityEvent] = []
    private var currentDayString: String = ""
    private var flushTimer: DispatchSourceTimer?
    private var isStopped = false

    // MARK: - Init / deinit

    init(
        logsURL: URL? = nil,
        flushThreshold: Int = 25,
        flushInterval: TimeInterval = 2.0
    ) {
        self.logsURL = logsURL
        self.flushThreshold = flushThreshold
        self.flushInterval = flushInterval
    }

    deinit {
        stopTimer()
    }

    // MARK: - Lifecycle

    /// Starts the background flush timer. Call when recording begins.
    func start(logsURL: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            self.logsURL = logsURL
            self.isStopped = false
            self.currentDayString = ActivityLogPaths.dayString()
            self.scheduleTimer()
        }
    }

    /// Flushes any remaining buffered events and stops the timer.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.flushBuffer()
            self.stopTimer()
        }
    }

    // MARK: - Event ingestion

    /// Appends an event to the write buffer. Thread-safe.
    func append(_ event: ActivityEvent) {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.handleDayRotationIfNeeded(for: event.timestamp)
            self.buffer.append(event)
            if self.buffer.count >= self.flushThreshold {
                self.flushBuffer()
            }
        }
    }

    /// Flushes any buffered events to disk immediately. Thread-safe.
    func flush() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.flushBuffer()
        }
    }

    /// Synchronously flushes buffered events to disk. Useful for testing.
    func flushSync() {
        queue.sync {
            guard !isStopped else { return }
            flushBuffer()
        }
    }

    // MARK: - Private: day rotation

    private func handleDayRotationIfNeeded(for date: Date) {
        let day = ActivityLogPaths.dayString(for: date)
        if day != currentDayString {
            // Flush any pending events for the old day before rotating
            flushBuffer()
            currentDayString = day
        }
    }

    // MARK: - Private: flush

    private func flushBuffer() {
        guard !buffer.isEmpty, let logsURL else { return }

        let events = buffer
        buffer.removeAll(keepingCapacity: true)

        // Determine the log file for the current day
        let logURL = logsURL.appendingPathComponent(currentDayString + ".jsonl")

        do {
            try ensureDirectory(logsURL)
            let lines = try events.map { try $0.jsonlLine() }.joined(separator: "\n") + "\n"
            guard let data = lines.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: logURL.path) {
                // Append to existing file
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try handle.write(contentsOf: data)
            } else {
                // Create new file
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Swallow write errors — recording must not crash the app.
            // Failures are diagnosable via the system log.
            NSLog("[ActivityLogWriter] Write error: %@", error.localizedDescription)
        }
    }

    // MARK: - Private: timer

    private func scheduleTimer() {
        stopTimer()
        guard flushInterval > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleDayRotationIfNeeded(for: Date())
            self.flushBuffer()
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: - Private: directory creation

    private func ensureDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
