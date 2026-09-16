import AppKit
import Foundation

// MARK: - Pipeline State

/// Observable state of the AI indexing pipeline.
enum PipelineState: Equatable {
    case idle
    case processing(clipId: Int64, progress: String)
    case paused
    case error(String)
}

struct AIIndexRepairResult {
    let rebuiltSearchIndex: Bool
    let requeuedClipCount: Int
}

// MARK: - AIIndexingPipeline

/// Orchestrates the AI processing pipeline: classify → describe (images) → embed.
///
/// Runs as a serial async Task (utility priority), processing one clip at a time.
/// Supports immediate enqueueing of new clips, backfill on launch/key change,
/// sleep/wake pause/resume, exponential backoff on rate limiting, and observable state.
final class AIIndexingPipeline {

    // MARK: - Shared Instance

    static let shared = AIIndexingPipeline(
        clipStore: ClipStore(dbQueue: DatabaseManager.shared.dbQueue),
        embeddingStore: EmbeddingStore(dbQueue: DatabaseManager.shared.dbQueue)
    )

    // MARK: - Dependencies

    private let clipStore: ClipStore
    private let embeddingStore: EmbeddingStore
    let classifier: ContentClassifier
    let imageDescriber: ImageDescriber
    let embeddingGenerator: EmbeddingGenerator
    private let mediaFileManager: MediaFileManager

    // MARK: - Configuration

    /// Delay between clips during backfill (nanoseconds). Reduces API pressure.
    let interClipDelayNanoseconds: UInt64
    /// Batch size for fetching unprocessed clips.
    let backfillBatchSize: Int
    /// Maximum processing attempts per clip before marking permanently failed.
    let maxRetries: Int
    /// Base delay before the first retry (nanoseconds). Doubles after each failed attempt.
    let retryBaseDelayNanoseconds: UInt64
    /// Interval for the periodic safety-net backfill scan. Catches clips that
    /// slipped through `enqueue` for any reason (state machine bugs, transient
    /// outages, AI re-enabled mid-session, etc.). Set to `.never` to disable.
    let safetyNetInterval: DispatchTimeInterval
    /// Failed clips are retried by the automatic repair scan after this delay.
    /// Manual "Repair Index" still requeues them immediately.
    let automaticFailedRetryDelay: TimeInterval

    // MARK: - State

    private(set) var state: PipelineState = .idle {
        didSet { onStateChange?(state) }
    }

    /// Called on the Task's context whenever `state` changes.
    var onStateChange: ((PipelineState) -> Void)?

    // MARK: - Internal Control

    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    /// Clip IDs enqueued for immediate processing (new clips from clipboard monitor).
    private var pendingClipIds: [Int64] = []
    private let controlLock = NSLock()
    private(set) var isSleeping = false
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var safetyNetTimer: DispatchSourceTimer?
    private let safetyNetQueue = DispatchQueue(
        label: "com.yourname.ClipVault.AIIndexingPipeline.SafetyNet",
        qos: .utility
    )

    // MARK: - Init

    init(
        clipStore: ClipStore,
        embeddingStore: EmbeddingStore,
        client: OpenAIClient = .shared,
        mediaFileManager: MediaFileManager = .shared,
        interClipDelayNanoseconds: UInt64 = 500_000_000,  // 500 ms
        backfillBatchSize: Int = 50,
        maxRetries: Int = 3,
        retryBaseDelayNanoseconds: UInt64 = 5_000_000_000,  // 5 seconds
        safetyNetInterval: DispatchTimeInterval = .seconds(300),  // 5 min
        automaticFailedRetryDelay: TimeInterval = 6 * 60 * 60
    ) {
        self.clipStore = clipStore
        self.embeddingStore = embeddingStore
        self.mediaFileManager = mediaFileManager
        self.interClipDelayNanoseconds = interClipDelayNanoseconds
        self.backfillBatchSize = backfillBatchSize
        self.maxRetries = max(maxRetries, 1)
        self.retryBaseDelayNanoseconds = retryBaseDelayNanoseconds
        self.safetyNetInterval = safetyNetInterval
        self.automaticFailedRetryDelay = automaticFailedRetryDelay
        self.classifier = ContentClassifier(client: client)
        self.imageDescriber = ImageDescriber(client: client)
        self.embeddingGenerator = EmbeddingGenerator(client: client, embeddingStore: embeddingStore)
    }

    // MARK: - Lifecycle

    func start() {
        registerSleepWakeNotifications()
        startSafetyNetTimer()
        triggerRepairAndBackfillIfNeeded()
    }

    func stop() {
        stopSafetyNetTimer()
        cancelPipeline()
        unregisterSleepWakeNotifications()
        setState(.idle)
    }

    // MARK: - New Clip Enqueueing

    /// Enqueues a newly inserted clip for immediate AI processing.
    func enqueue(clipId: Int64) {
        guard Settings.shared.isAIEnabled else { return }
        controlLock.lock()
        pendingClipIds.append(clipId)
        controlLock.unlock()
        startPipelineTaskIfIdle()
    }

    // MARK: - Backfill

    /// Starts a backfill pass if the key is present and the pipeline is not already running.
    func triggerBackfillIfNeeded() {
        guard Settings.shared.isAIEnabled else {
            setState(.paused)
            return
        }
        startPipelineTaskIfIdle()
    }

    /// Resets stale/incomplete AI rows, then starts the normal backfill pass.
    func triggerRepairAndBackfillIfNeeded() {
        guard Settings.shared.isAIEnabled else {
            setState(.paused)
            return
        }
        let repaired = (try? clipStore.resetClipsNeedingAutomaticAIRepair(
            failedRetryDelay: automaticFailedRetryDelay
        )) ?? 0
        if repaired > 0 {
            NSLog("ClipVault: queued %d clips for automatic AI index repair", repaired)
        }
        startPipelineTaskIfIdle()
    }

    /// Resets all clips to unprocessed and kicks off a full re-index.
    func reindexAll() throws {
        cancelPipeline()
        controlLock.lock()
        pendingClipIds.removeAll()
        controlLock.unlock()
        try clipStore.resetAllToUnprocessed()
        triggerBackfillIfNeeded()
    }

    /// Rebuilds the search index and re-queues only clips missing AI artifacts.
    @discardableResult
    func repairIndexingIssues() throws -> AIIndexRepairResult {
        cancelPipeline()
        controlLock.lock()
        pendingClipIds.removeAll()
        controlLock.unlock()
        try clipStore.rebuildSearchIndex()
        let requeuedClipCount = try clipStore.resetClipsNeedingAIRepair()
        triggerBackfillIfNeeded()
        return AIIndexRepairResult(rebuiltSearchIndex: true, requeuedClipCount: requeuedClipCount)
    }

    // MARK: - Pipeline Task

    private func startPipelineTaskIfIdle() {
        controlLock.lock()
        if let task = pipelineTask, !task.isCancelled {
            controlLock.unlock()
            return
        }
        pipelineGeneration += 1
        let generation = pipelineGeneration
        pipelineTask = Task(priority: .utility) { [weak self] in
            await self?.runLoop()
            // Clear the reference so the next enqueue() can spin up a fresh task.
            // Without this, the completed (but non-cancelled) Task would block
            // startPipelineTaskIfIdle's guard and new clips would never process.
            self?.clearPipelineTask(generation: generation)
        }
        controlLock.unlock()
    }

    private func cancelPipeline() {
        controlLock.lock()
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        controlLock.unlock()
    }

    private func clearPipelineTask(generation: Int) {
        controlLock.lock()
        if pipelineGeneration == generation {
            pipelineTask = nil
        }
        controlLock.unlock()
    }

    private func popPendingClipId() -> Int64? {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !pendingClipIds.isEmpty else { return nil }
        return pendingClipIds.removeFirst()
    }

    // MARK: - Main Loop

    private func runLoop() async {
        var processedAny = false
        defer {
            if processedAny {
                embeddingStore.quantize()
                embeddingStore.preloadQuantized()
            }
        }

        while !Task.isCancelled {
            // Pause while sleeping
            if isSleeping {
                setState(.paused)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            guard Settings.shared.isAIEnabled else {
                setState(.paused)
                break
            }

            // Determine the next clip to process
            let clip: ClipRecord?
            if let id = popPendingClipId() {
                clip = try? clipStore.fetchById(id)
            } else {
                let batch = (try? clipStore.fetchUnprocessed(limit: backfillBatchSize)) ?? []
                clip = batch.first
            }

            guard let clip, let clipId = clip.id else {
                // Nothing left to process
                setState(.idle)
                break
            }

            let remaining = (try? countUnprocessed()) ?? 0
            let progressLabel = remaining > 1 ? "~\(remaining) remaining" : "finalizing"
            setState(.processing(clipId: clipId, progress: progressLabel))

            let stop = await processClip(clip)
            processedAny = true
            if stop { break }

            // Throttle between clips
            if interClipDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: interClipDelayNanoseconds)
            }
        }
    }

    // MARK: - Single-Clip Processing

    /// Outcome of a single processing attempt (no DB side effects).
    private enum ProcessResult {
        case success(tags: String?, imageDescription: String?)
        case stopPipeline
        case retryable(Error)
    }

    /// Processes a single clip through classify → describe → embed, retrying
    /// up to `maxRetries` times with exponential backoff on transient errors.
    /// Returns `true` when the pipeline should stop (e.g. bad API key).
    @discardableResult
    func processClip(_ clip: ClipRecord) async -> Bool {
        guard let clipId = clip.id else { return false }

        for attempt in 1...maxRetries {
            if Task.isCancelled { return false }

            let result = await attemptProcess(clip)
            switch result {
            case .success(let tags, let imageDescription):
                if attempt > 1 {
                    NSLog("ClipVault: Clip %lld succeeded on attempt %d/%d", clipId, attempt, maxRetries)
                }
                try? clipStore.markProcessed(id: clipId, tags: tags, imageDescription: imageDescription)
                return false

            case .stopPipeline:
                return true

            case .retryable(let error):
                NSLog("ClipVault: Clip %lld attempt %d/%d failed: %@",
                      clipId, attempt, maxRetries, error.localizedDescription)
                if attempt < maxRetries {
                    let backoff = retryBaseDelayNanoseconds * (1 << UInt64(attempt - 1))
                    try? await Task.sleep(nanoseconds: backoff)
                }
            }
        }

        NSLog("ClipVault: Clip %lld failed after %d attempts, marking as permanently failed", clipId, maxRetries)
        try? clipStore.markFailed(id: clipId)
        return false
    }

    /// Runs a single processing attempt without touching the database.
    private func attemptProcess(_ clip: ClipRecord) async -> ProcessResult {
        var updatedClip = clip

        do {
            if clip.contentType == "image", let filename = clip.mediaFileName {
                guard let imageData = try? mediaFileManager.load(filename: filename) else {
                    throw AIIndexingError.imageMediaUnavailable
                }
                guard let description = await imageDescriber.describe(imageData: imageData),
                      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIIndexingError.imageDescriptionUnavailable
                }
                updatedClip.imageDescription = description
            }

            let tags = try await classifier.classify(clip: updatedClip)
            let tagsJSON: String?
            if tags.isEmpty {
                tagsJSON = nil
            } else {
                let data = try JSONSerialization.data(withJSONObject: tags)
                tagsJSON = String(data: data, encoding: .utf8)
            }
            updatedClip.tags = tagsJSON

            _ = try await embeddingGenerator.generateAndStore(clip: updatedClip)

            return .success(tags: tagsJSON, imageDescription: updatedClip.imageDescription)

        } catch OpenAIError.httpError(let code, _) where code == 401 {
            setState(.error("Invalid API key (401). Update your key in Preferences."))
            return .stopPipeline

        } catch OpenAIError.apiKeyMissing {
            setState(.error("AI API key is not configured."))
            return .stopPipeline

        } catch {
            return .retryable(error)
        }
    }

    // MARK: - Safety-net Timer

    /// Starts a periodic timer that wakes the pipeline to check for unprocessed
    /// clips. This is belt-and-suspenders insurance — `enqueue` should normally
    /// be enough, but a periodic poll catches anything missed by state-machine
    /// bugs, transient API outages, or AI being re-enabled mid-session.
    private func startSafetyNetTimer() {
        guard safetyNetTimer == nil else { return }
        // .never is represented as Int.max nanoseconds — treat as disabled.
        if case .never = safetyNetInterval { return }
        let source = DispatchSource.makeTimerSource(queue: safetyNetQueue)
        source.schedule(
            deadline: .now() + safetyNetInterval,
            repeating: safetyNetInterval,
            leeway: .seconds(30)
        )
        source.setEventHandler { [weak self] in
            self?.runSafetyNetTick()
        }
        source.resume()
        safetyNetTimer = source
    }

    private func stopSafetyNetTimer() {
        safetyNetTimer?.cancel()
        safetyNetTimer = nil
    }

    /// Fires on the safety-net timer's queue. Cheap pre-check avoids spinning
    /// up the pipeline task when there's nothing to do.
    func runSafetyNetTick() {
        guard Settings.shared.isAIEnabled else { return }
        guard !isSleeping else { return }
        let repaired = (try? clipStore.resetClipsNeedingAutomaticAIRepair(
            failedRetryDelay: automaticFailedRetryDelay
        )) ?? 0
        let pending = (try? clipStore.fetchUnprocessed(limit: 1)) ?? []
        guard repaired > 0 || !pending.isEmpty else { return }
        triggerBackfillIfNeeded()
    }

    // MARK: - Sleep / Wake

    private func registerSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepObs = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleSleep() }

        let wakeObs = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleWake() }

        sleepWakeObservers = [sleepObs, wakeObs]
    }

    private func unregisterSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers.forEach { center.removeObserver($0) }
        sleepWakeObservers.removeAll()
    }

    func handleSleep() {
        isSleeping = true
        setState(.paused)
    }

    func handleWake() {
        isSleeping = false
        triggerRepairAndBackfillIfNeeded()
    }

    // MARK: - Helpers

    private func setState(_ newState: PipelineState) {
        state = newState
    }

    private func countUnprocessed() throws -> Int {
        try clipStore.fetchUnprocessed(limit: 10_000).count
    }
}

enum AIIndexingError: LocalizedError {
    case imageMediaUnavailable
    case imageDescriptionUnavailable

    var errorDescription: String? {
        switch self {
        case .imageMediaUnavailable:
            return "Image media file could not be loaded"
        case .imageDescriptionUnavailable:
            return "Image description could not be generated"
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let aiPipelineStateDidChange = Notification.Name("AIIndexingPipelineStateDidChange")
}
