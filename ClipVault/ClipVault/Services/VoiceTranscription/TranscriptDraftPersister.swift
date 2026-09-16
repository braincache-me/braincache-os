import Foundation

/// Keeps an in-progress voice transcript persisted as a single clip that is
/// created on the first flush and updated in place on every later one.
///
/// Why: before this, the transcript only reached the clip store when the
/// recording was stopped. A dead battery, kernel panic, or force-quit an
/// hour into a meeting lost the entire transcript. `VoiceTranscriptionService`
/// now flushes through this object every few seconds, so at most a few
/// seconds of text can ever be lost — and the final save reuses the same
/// clip, so history never shows a duplicate.
///
/// Pure orchestration over two injected closures (insert / update) so the
/// dedupe and reuse rules are unit-testable without a database.
final class TranscriptDraftPersister {

    /// Inserts a new draft clip and returns its id.
    typealias Insert = (String) throws -> Int64
    /// Rewrites the text of an existing clip. `isFinal` is `true` for the
    /// last save of the session so the store can re-queue AI indexing.
    typealias Update = (_ clipId: Int64, _ text: String, _ isFinal: Bool) throws -> Void

    private(set) var clipId: Int64?
    private(set) var lastSavedText = ""
    private(set) var writeCount = 0

    private let insert: Insert
    private let update: Update
    private let log: (String) -> Void

    init(insert: @escaping Insert, update: @escaping Update, log: @escaping (String) -> Void = { _ in }) {
        self.insert = insert
        self.update = update
        self.log = log
    }

    /// Persists `text` if it is non-empty and differs from the last saved
    /// version. Returns the clip id (existing or newly created), or `nil`
    /// when nothing has been persisted yet / the write failed.
    @discardableResult
    func flush(text: String, isFinal: Bool = false) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clipId }

        if let id = clipId {
            // A final save always goes through so the store can re-index,
            // even when the text hasn't changed since the last draft flush.
            guard isFinal || trimmed != lastSavedText else { return id }
            do {
                try update(id, trimmed, isFinal)
                lastSavedText = trimmed
                writeCount += 1
            } catch {
                log("draft update failed: \(error)")
            }
            return id
        }

        do {
            let id = try insert(trimmed)
            clipId = id
            lastSavedText = trimmed
            writeCount += 1
            return id
        } catch {
            log("draft insert failed: \(error)")
            return nil
        }
    }

    /// Forgets the current draft so the next flush starts a new clip. Does
    /// not delete anything — the persisted clip stays in history.
    func reset() {
        clipId = nil
        lastSavedText = ""
        writeCount = 0
    }
}
