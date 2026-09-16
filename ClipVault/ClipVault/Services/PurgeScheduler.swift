import Foundation

/// Runs a daily purge of old and excess clipboard entries.
final class PurgeScheduler {

    private let store: ClipStore
    private let settings: Settings
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.yourname.ClipVault.PurgeScheduler", qos: .background)

    /// Interval between purge runs (override in tests).
    var interval: DispatchTimeInterval = .seconds(86400)

    /// Optional embedding store to re-quantize and preload after purge.
    var embeddingStore: EmbeddingStore?

    init(store: ClipStore, settings: Settings = .shared) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        source.setEventHandler { [weak self] in
            self?.runPurge()
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Executes both purge strategies immediately (also callable from tests).
    func runPurge() {
        let days = settings.autoPurgeAgeDays
        let max = settings.maxHistoryCount
        do {
            try store.purgeOlderThan(days: days)
            try store.purgeExceedingCount(max: max)
        } catch {
            NSLog("ClipVault: PurgeScheduler error: \(error)")
        }
        // Rebuild the vector quantization index and refresh in-memory preload
        // after bulk deletes so approximate search results stay accurate.
        embeddingStore?.quantize()
        embeddingStore?.preloadQuantized()
    }
}
