import XCTest
import GRDB
@testable import ClipVault

/// Covers the pure logic behind the voice panel's "Save recording" feature and
/// the crash-safe transcript draft persistence.
final class VoiceMediaRecordingTests: XCTestCase {

    // MARK: - Checkbox state machine

    func testCheckboxStartsFileWhenSessionIsLive() {
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: true, sessionRecording: true, mediaRecording: false),
            .startNow
        )
    }

    func testCheckboxArmsWhenNoSessionYet() {
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: true, sessionRecording: false, mediaRecording: false),
            .arm
        )
    }

    func testUncheckStopsLiveFile() {
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: false, sessionRecording: true, mediaRecording: true),
            .stopNow
        )
        // Even if the session already ended, an in-flight file is finalised.
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: false, sessionRecording: false, mediaRecording: true),
            .stopNow
        )
    }

    func testUncheckWithoutFileDisarms() {
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: false, sessionRecording: false, mediaRecording: false),
            .disarm
        )
    }

    func testCheckWhileAlreadyRecordingIsNoop() {
        XCTAssertEqual(
            VoiceMediaRecordingPolicy.action(checkboxOn: true, sessionRecording: true, mediaRecording: true),
            .none
        )
    }

    func testAttachedWindowLockedWhileFileIsWritten() {
        XCTAssertFalse(VoiceMediaRecordingPolicy.canChangeAttachedWindow(mediaRecording: true))
        XCTAssertTrue(VoiceMediaRecordingPolicy.canChangeAttachedWindow(mediaRecording: false))
    }

    // MARK: - File naming / video geometry

    private func makeWindow(appName: String, size: CGSize = CGSize(width: 1280, height: 800)) -> CapturableWindow {
        CapturableWindow(
            id: 42,
            bundleID: "us.zoom.xos",
            appName: appName,
            title: "Meeting",
            frame: CGRect(origin: .zero, size: size),
            appIcon: nil
        )
    }

    private var fixedDate: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 1
        comps.hour = 14; comps.minute = 3; comps.second = 22
        return Calendar.current.date(from: comps)!
    }

    func testAudioOnlyFileIsM4A() {
        XCTAssertEqual(
            VoiceMediaRecorder.fileName(startedAt: fixedDate, mode: .audioOnly),
            "Voice 2026-09-01 14-03-22.m4a"
        )
    }

    func testWindowFileIsMovWithSanitisedAppName() {
        let window = makeWindow(appName: "Zoom: Call / Room")
        XCTAssertEqual(
            VoiceMediaRecorder.fileName(startedAt: fixedDate, mode: .window(window)),
            "Voice 2026-09-01 14-03-22 - Zoom Call Room.mov"
        )
    }

    func testEmptyAppNameFallsBackToPlainMov() {
        let window = makeWindow(appName: "///")
        XCTAssertEqual(
            VoiceMediaRecorder.fileName(startedAt: fixedDate, mode: .window(window)),
            "Voice 2026-09-01 14-03-22.mov"
        )
    }

    func testVideoDimensionsCapLongEdgeAndStayEven() {
        let dims = VoiceMediaRecorder.videoDimensions(
            forWindowSize: CGSize(width: 3840, height: 2161), maxLongEdge: 1920
        )
        XCTAssertEqual(dims.width, 1920)
        XCTAssertEqual(dims.height, 1080)
        XCTAssertEqual(dims.width % 2, 0)
        XCTAssertEqual(dims.height % 2, 0)
    }

    func testVideoDimensionsDoNotUpscaleSmallWindows() {
        let dims = VoiceMediaRecorder.videoDimensions(
            forWindowSize: CGSize(width: 641, height: 399), maxLongEdge: 1920
        )
        XCTAssertEqual(dims.width, 640)
        XCTAssertEqual(dims.height, 398)
    }

    func testVideoDimensionsNeverBelowTwoPixels() {
        let dims = VoiceMediaRecorder.videoDimensions(forWindowSize: .zero, maxLongEdge: 1920)
        XCTAssertEqual(dims.width, 2)
        XCTAssertEqual(dims.height, 2)
    }

    func testVideoBitrateIsClamped() {
        XCTAssertEqual(VoiceMediaRecorder.videoBitrate(width: 320, height: 200, frameRate: 15), 1_000_000)
        XCTAssertEqual(VoiceMediaRecorder.videoBitrate(width: 3840, height: 2160, frameRate: 60), 8_000_000)
        let mid = VoiceMediaRecorder.videoBitrate(width: 1920, height: 1080, frameRate: 15)
        XCTAssertGreaterThan(mid, 1_000_000)
        XCTAssertLessThan(mid, 8_000_000)
    }

    func testClosedWindowIsReportedMissing() {
        // CGWindowID 0 is never a real window.
        XCTAssertFalse(VoiceMediaRecorder.windowExists(0))
    }

    // MARK: - Recordings folder

    func testRecordingsFolderDefaultsToMovies() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            Settings.voiceRecordingsFolderURL(configuredPath: "", homeDirectory: home, isProd: true).path,
            "/Users/tester/Movies/BrainCache Recordings"
        )
        XCTAssertEqual(
            Settings.voiceRecordingsFolderURL(configuredPath: "  ", homeDirectory: home, isProd: false).path,
            "/Users/tester/Movies/BrainCache Recordings (Dev)"
        )
    }

    func testRecordingsFolderHonoursConfiguredPath() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            Settings.voiceRecordingsFolderURL(configuredPath: "/Volumes/Ext/Rec", homeDirectory: home, isProd: true).path,
            "/Volumes/Ext/Rec"
        )
    }

    // MARK: - Menu-bar hint copy

    func testSourceLostMessageNamesTheApp() {
        let message = MeetingPromptPolicy.mediaSourceLostMessage(appName: "Zoom", saved: true)
        XCTAssertTrue(message.hasPrefix("The Zoom window was closed"))
        XCTAssertTrue(message.contains("was saved"))
        XCTAssertTrue(message.contains("Transcription is still running"))
    }

    func testSourceLostMessageWhenNothingSaved() {
        let message = MeetingPromptPolicy.mediaSourceLostMessage(appName: "", saved: false)
        XCTAssertTrue(message.hasPrefix("The attached window was closed"))
        XCTAssertTrue(message.contains("nothing long enough to save"))
    }

    // MARK: - Draft persistence (pure)

    private final class FakeStore {
        var inserted: [String] = []
        var updated: [(Int64, String, Bool)] = []
        var nextId: Int64 = 100
        var failInsert = false

        func insert(_ text: String) throws -> Int64 {
            if failInsert { throw NSError(domain: "test", code: 1) }
            inserted.append(text)
            nextId += 1
            return nextId
        }

        func update(_ id: Int64, _ text: String, _ isFinal: Bool) throws {
            updated.append((id, text, isFinal))
        }
    }

    private func makePersister(_ store: FakeStore) -> TranscriptDraftPersister {
        TranscriptDraftPersister(insert: store.insert, update: store.update)
    }

    func testFirstFlushInsertsAndLaterFlushesUpdateSameClip() {
        let store = FakeStore()
        let persister = makePersister(store)

        XCTAssertEqual(persister.flush(text: "Hello"), 101)
        XCTAssertEqual(persister.flush(text: "Hello world"), 101)
        XCTAssertEqual(persister.flush(text: "Hello world, again"), 101)

        XCTAssertEqual(store.inserted, ["Hello"])
        XCTAssertEqual(store.updated.map { $0.1 }, ["Hello world", "Hello world, again"])
        XCTAssertEqual(store.updated.map { $0.2 }, [false, false])
    }

    func testUnchangedTextDoesNotWrite() {
        let store = FakeStore()
        let persister = makePersister(store)
        persister.flush(text: "Same")
        persister.flush(text: "Same")
        persister.flush(text: "  Same \n")
        XCTAssertEqual(persister.writeCount, 1)
        XCTAssertTrue(store.updated.isEmpty)
    }

    func testEmptyTextNeverCreatesAClip() {
        let store = FakeStore()
        let persister = makePersister(store)
        XCTAssertNil(persister.flush(text: ""))
        XCTAssertNil(persister.flush(text: "   \n"))
        XCTAssertTrue(store.inserted.isEmpty)
        XCTAssertNil(persister.clipId)
    }

    func testFinalFlushAlwaysWritesAndFlagsFinal() {
        let store = FakeStore()
        let persister = makePersister(store)
        persister.flush(text: "Done.")
        // Same text, but final → must go through so the store can re-index.
        XCTAssertEqual(persister.flush(text: "Done.", isFinal: true), 101)
        XCTAssertEqual(store.updated.count, 1)
        XCTAssertEqual(store.updated.first?.2, true)
    }

    func testInsertFailureIsRetriedOnNextFlush() {
        let store = FakeStore()
        store.failInsert = true
        let persister = makePersister(store)
        XCTAssertNil(persister.flush(text: "First try"))
        store.failInsert = false
        XCTAssertEqual(persister.flush(text: "Second try"), 101)
        XCTAssertEqual(store.inserted, ["Second try"])
    }

    func testResetStartsANewClip() {
        let store = FakeStore()
        let persister = makePersister(store)
        persister.flush(text: "Session one")
        persister.reset()
        XCTAssertNil(persister.clipId)
        XCTAssertEqual(persister.flush(text: "Session two"), 102)
        XCTAssertEqual(store.inserted, ["Session one", "Session two"])
    }

    // MARK: - Draft persistence (real ClipStore)

    func testUpdateTextContentRewritesClipInPlaceAndKeepsSearchIndexInSync() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ClipStore(dbQueue: manager.dbQueue)

        let persister = TranscriptDraftPersister(
            insert: { text in
                try store.insert(entry: ClipboardEntry(
                    contentType: .text,
                    textContent: text,
                    dataHash: Hashing.sha256(data: Data(text.utf8)),
                    sourceApp: ClipRecord.audioTranscriptSourceApp,
                    byteSize: text.utf8.count
                ))
            },
            update: { id, text, isFinal in
                try store.updateTextContent(id: id, text: text, resetAIProcessing: isFinal)
            }
        )

        let id = try XCTUnwrap(persister.flush(text: "quarterly planning kickoff"))
        try store.markProcessed(id: id, tags: "[\"meeting\"]", imageDescription: nil)
        XCTAssertEqual(persister.flush(text: "quarterly planning kickoff with budget review"), id)

        // Draft flush: text + hash updated, AI state untouched.
        var record = try XCTUnwrap(store.fetchById(id))
        XCTAssertEqual(record.textContent, "quarterly planning kickoff with budget review")
        XCTAssertEqual(record.dataHash, Hashing.sha256(data: Data("quarterly planning kickoff with budget review".utf8)))
        XCTAssertEqual(record.byteSize, "quarterly planning kickoff with budget review".utf8.count)
        XCTAssertEqual(record.aiProcessed, 1)
        XCTAssertEqual(record.tags, "[\"meeting\"]")

        // The FTS trigger followed the update.
        XCTAssertEqual(try store.search(query: "budget").map(\.id), [id])
        XCTAssertEqual(try store.fetchRecent().count, 1, "draft flushes must never create a second clip")

        // Final flush: same row, AI processing reset so the pipeline re-runs.
        XCTAssertEqual(persister.flush(text: "quarterly planning kickoff with budget review", isFinal: true), id)
        record = try XCTUnwrap(store.fetchById(id))
        XCTAssertEqual(record.aiProcessed, 0)
        XCTAssertNil(record.tags)
        XCTAssertEqual(try store.fetchRecent().count, 1)
    }

    // MARK: - Ring buffer

    func testStereoRingBufferMixesAndDrains() {
        var ring = StereoRingBuffer(capacity: 8)
        for i in 0..<4 {
            ring.write(left: Float(i + 1), right: Float(-(i + 1)))
        }
        var out = [Float](repeating: 0.5, count: 12) // 6 frames interleaved
        let mixed = out.withUnsafeMutableBufferPointer { ring.mixInto(interleaved: $0.baseAddress!, frameCount: 6) }
        XCTAssertEqual(mixed, 4)
        XCTAssertEqual(out[0], 1.5)
        XCTAssertEqual(out[1], -0.5)
        XCTAssertEqual(out[6], 4.5)
        XCTAssertEqual(out[7], -3.5)
        XCTAssertEqual(out[8], 0.5, "frames beyond what was available stay untouched")
        XCTAssertEqual(ring.count, 0)
    }

    func testStereoRingBufferOverwritesOldestWhenFull() {
        var ring = StereoRingBuffer(capacity: 3)
        for i in 1...5 {
            ring.write(left: Float(i), right: 0)
        }
        XCTAssertEqual(ring.count, 3)
        var out = [Float](repeating: 0, count: 6)
        out.withUnsafeMutableBufferPointer { _ = ring.mixInto(interleaved: $0.baseAddress!, frameCount: 3) }
        XCTAssertEqual([out[0], out[2], out[4]], [3, 4, 5])
    }
}
