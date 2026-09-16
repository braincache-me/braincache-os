import AppKit
import XCTest
@testable import ClipVault

private func makeMouseEvent(
    type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

// MARK: - Menu structure indices (idle state, 15 items)
// 0  About BrainCache
// 1  Preferences…
// 2  Chat with Data
// 3  Open Writing Assistant
// 4  ── separator ──
// 5  Start Voice Recording
// 6  Start Voice Recording with System Audio
// 7  ── separator ──
// 8  Start Activity Capture
// 9  Pause Activity Capture (title changes to "Resume" when paused)
// 10 Stop Activity Capture
// 11 ── separator ──
// 12 Activity History…
// 13 ── separator ──
// 14 Quit BrainCache

final class StatusMenuBuilderTests: XCTestCase {

    private var builder: StatusMenuBuilder!

    override func setUp() {
        super.setUp()
        builder = StatusMenuBuilder()
    }

    // MARK: - Item count

    func testMenuItemCountIdle() {
        let menu = builder.buildMenu(recorderState: .idle)
        XCTAssertEqual(menu.items.count, 15)
    }

    func testMenuItemCountRecording() {
        let menu = builder.buildMenu(recorderState: .recording)
        XCTAssertEqual(menu.items.count, 15)
    }

    func testMenuItemCountPaused() {
        let menu = builder.buildMenu(recorderState: .paused)
        XCTAssertEqual(menu.items.count, 15)
    }

    func testMenuItemCountVoicePanelHidden() {
        let menu = builder.buildMenu(voiceRecordingActive: true, voicePanelVisible: false)
        XCTAssertEqual(menu.items.count, 16)
    }

    // MARK: - Standard item titles

    func testAboutItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[0].title, "About BrainCache")
    }

    func testPreferencesItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[1].title, "Preferences\u{2026}")
    }

    func testPreferencesItemKeyEquivalent() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[1].keyEquivalent, ",")
    }

    func testPreferencesItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[1].action, #selector(AppDelegate.openPreferences))
    }

    // MARK: - Separators

    func testFirstSeparatorAfterChatItem() {
        let menu = builder.buildMenu()
        XCTAssertTrue(menu.items[4].isSeparatorItem)
    }

    func testSecondSeparatorAfterActivityControls() {
        let menu = builder.buildMenu()
        XCTAssertTrue(menu.items[11].isSeparatorItem)
    }

    func testThirdSeparatorBeforeQuit() {
        let menu = builder.buildMenu()
        XCTAssertTrue(menu.items[13].isSeparatorItem)
    }

    func testSeparatorAfterVoiceControls() {
        let menu = builder.buildMenu()
        XCTAssertTrue(menu.items[7].isSeparatorItem)
    }

    // MARK: - Writing Assistant item

    func testWritingAssistantItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[3].title, "Open Writing Assistant")
    }

    func testWritingAssistantItemAction() {
        let previousKey = Settings.shared.openAIAPIKey
        Settings.shared.openAIAPIKey = "sk-test"
        defer { Settings.shared.openAIAPIKey = previousKey }

        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[3].action, #selector(AppDelegate.triggerAIRewriteAction))
    }

    // MARK: - Voice Recording items

    func testStartVoiceRecordingItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[5].title, "Start Voice Recording")
    }

    func testStartVoiceRecordingItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[5].action, #selector(AppDelegate.startVoiceRecordingAction))
    }

    func testStartVoiceRecordingWithSystemAudioItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[6].title, "Start Voice Recording with System Audio")
    }

    func testStartVoiceRecordingWithSystemAudioItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[6].action, #selector(AppDelegate.startVoiceRecordingWithSystemAudioAction))
    }

    func testVoiceRecordingStatusWhenPanelVisible() {
        let menu = builder.buildMenu(voiceRecordingActive: true, voicePanelVisible: true)
        XCTAssertEqual(menu.items[5].title, "Voice Recording\u{2026}")
        XCTAssertFalse(menu.items[5].isEnabled)
    }

    func testVoiceRecordingStatusWhenPanelHidden() {
        let menu = builder.buildMenu(voiceRecordingActive: true, voicePanelVisible: false)
        XCTAssertEqual(menu.items[5].title, "Voice Recording (panel hidden)\u{2026}")
        XCTAssertFalse(menu.items[5].isEnabled)
    }

    func testShowVoiceRecordingPanelItemWhenPanelHidden() {
        let menu = builder.buildMenu(voiceRecordingActive: true, voicePanelVisible: false)
        XCTAssertEqual(menu.items[6].title, "Show Voice Recording Panel")
        XCTAssertEqual(menu.items[6].action, #selector(AppDelegate.showVoiceRecordingPanelAction))
    }

    func testStopVoiceRecordingItemWhenRecording() {
        let menu = builder.buildMenu(voiceRecordingActive: true, voicePanelVisible: true)
        XCTAssertEqual(menu.items[6].title, "Stop Voice Recording")
        XCTAssertEqual(menu.items[6].action, #selector(AppDelegate.stopVoiceRecordingAction))
    }

    // MARK: - Activity Capture items (idle state)

    func testStartItemTitle() {
        let menu = builder.buildMenu(recorderState: .idle)
        XCTAssertEqual(menu.items[8].title, "Start Activity Capture")
    }

    func testStartItemEnabledWhenIdle() {
        let menu = builder.buildMenu(recorderState: .idle)
        XCTAssertEqual(menu.items[8].action, #selector(AppDelegate.startActivityCaptureAction))
    }

    func testStartItemDisabledWhenRecording() {
        let menu = builder.buildMenu(recorderState: .recording)
        XCTAssertNil(menu.items[8].action)
    }

    func testStartItemDisabledWhenPaused() {
        let menu = builder.buildMenu(recorderState: .paused)
        XCTAssertNil(menu.items[8].action)
    }

    // MARK: - Pause / Resume item

    func testPauseItemTitleWhenRecording() {
        let menu = builder.buildMenu(recorderState: .recording)
        XCTAssertEqual(menu.items[9].title, "Pause Activity Capture")
    }

    func testResumeItemTitleWhenPaused() {
        let menu = builder.buildMenu(recorderState: .paused)
        XCTAssertEqual(menu.items[9].title, "Resume Activity Capture")
    }

    func testPauseItemDisabledWhenIdle() {
        let menu = builder.buildMenu(recorderState: .idle)
        XCTAssertNil(menu.items[9].action)
    }

    func testPauseItemActionWhenRecording() {
        let menu = builder.buildMenu(recorderState: .recording)
        XCTAssertEqual(menu.items[9].action, #selector(AppDelegate.pauseActivityCaptureAction))
    }

    func testResumeItemActionWhenPaused() {
        let menu = builder.buildMenu(recorderState: .paused)
        XCTAssertEqual(menu.items[9].action, #selector(AppDelegate.resumeActivityCaptureAction))
    }

    // MARK: - Stop item

    func testStopItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[10].title, "Stop Activity Capture")
    }

    func testStopItemDisabledWhenIdle() {
        let menu = builder.buildMenu(recorderState: .idle)
        XCTAssertNil(menu.items[10].action)
    }

    func testStopItemEnabledWhenRecording() {
        let menu = builder.buildMenu(recorderState: .recording)
        XCTAssertEqual(menu.items[10].action, #selector(AppDelegate.stopActivityCaptureAction))
    }

    func testStopItemEnabledWhenPaused() {
        let menu = builder.buildMenu(recorderState: .paused)
        XCTAssertEqual(menu.items[10].action, #selector(AppDelegate.stopActivityCaptureAction))
    }

    // MARK: - Activity History item

    func testActivityHistoryItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[12].title, "Activity History\u{2026}")
    }

    func testActivityHistoryItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[12].action, #selector(AppDelegate.openActivityHistory))
    }

    func testActivityHistoryItemKeyEquivalent() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[12].keyEquivalent, "h")
    }

    func testActivityHistoryItemModifierMask() {
        let menu = builder.buildMenu()
        XCTAssertTrue(menu.items[12].keyEquivalentModifierMask.contains(.option))
        XCTAssertTrue(menu.items[12].keyEquivalentModifierMask.contains(.command))
    }

    // MARK: - Quit item

    func testQuitItemTitle() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[14].title, "Quit BrainCache")
    }

    func testQuitItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[14].action, #selector(NSApplication.terminate(_:)))
    }

    func testQuitItemKeyEquivalent() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[14].keyEquivalent, "q")
    }

    func testAboutItemAction() {
        let menu = builder.buildMenu()
        XCTAssertEqual(menu.items[0].action, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    }
}

// MARK: - StatusItemManager click routing

final class StatusItemManagerTests: XCTestCase {

    func testLeftClickMapsToSearchPanelToggle() {
        let event = makeMouseEvent(type: .leftMouseUp)
        XCTAssertEqual(StatusItemManager.clickAction(for: event), .toggleSearchPanel)
    }

    func testRightClickMapsToMenu() {
        let event = makeMouseEvent(type: .rightMouseUp)
        XCTAssertEqual(StatusItemManager.clickAction(for: event), .showMenu)
    }

    func testControlClickMapsToMenu() {
        let event = makeMouseEvent(type: .leftMouseUp, modifiers: .control)
        XCTAssertEqual(StatusItemManager.clickAction(for: event), .showMenu)
    }
}

// MARK: - StatusItemManager recorder state

final class StatusItemManagerRecorderStateTests: XCTestCase {

    func testInitialRecorderStateIsIdle() {
        let manager = StatusItemManager()
        XCTAssertEqual(manager.recorderState, .idle)
    }

    func testUpdateRecorderStateChangesState() {
        let manager = StatusItemManager()
        manager.updateRecorderState(.recording)
        XCTAssertEqual(manager.recorderState, .recording)
    }

    func testUpdateRecorderStatePaused() {
        let manager = StatusItemManager()
        manager.updateRecorderState(.paused)
        XCTAssertEqual(manager.recorderState, .paused)
    }

    func testInitialWritingRewriteStateIsInactive() {
        let manager = StatusItemManager()
        XCTAssertFalse(manager.writingRewriteActive)
    }

    func testUpdateWritingRewriteStateChangesState() {
        let manager = StatusItemManager()
        manager.updateWritingRewriteState(active: true)
        XCTAssertTrue(manager.writingRewriteActive)
        manager.updateWritingRewriteState(active: false)
        XCTAssertFalse(manager.writingRewriteActive)
    }

    func testRecorderStateReflectedInMenuPauseTitle() {
        let manager = StatusItemManager()
        manager.updateRecorderState(.recording)
        // The menu should show "Pause Activity Capture" when recording.
        // We verify by re-building: the state is plumbed through the builder.
        let builder = StatusMenuBuilder()
        let menu = builder.buildMenu(recorderState: manager.recorderState)
        XCTAssertEqual(menu.items[9].title, "Pause Activity Capture")
    }

    func testRecorderStateReflectedInMenuResumeTitle() {
        let manager = StatusItemManager()
        manager.updateRecorderState(.paused)
        let builder = StatusMenuBuilder()
        let menu = builder.buildMenu(recorderState: manager.recorderState)
        XCTAssertEqual(menu.items[9].title, "Resume Activity Capture")
    }
}
