import XCTest
@testable import ClipVault

final class SettingsTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // MARK: - Defaults

    func testDefaultHotkeyKeyCode() {
        XCTAssertEqual(settings.hotkeyKeyCode, Settings.Defaults.hotkeyKeyCode)
    }

    func testDefaultHotkeyModifiers() {
        XCTAssertEqual(settings.hotkeyModifiers, Settings.Defaults.hotkeyModifiers)
    }

    func testDefaultMaxHistoryCount() {
        XCTAssertEqual(settings.maxHistoryCount, Settings.Defaults.maxHistoryCount)
    }

    func testDefaultAutoPurgeAgeDays() {
        XCTAssertEqual(settings.autoPurgeAgeDays, Settings.Defaults.autoPurgeAgeDays)
    }

    func testDefaultExcludedBundleIDsIsEmpty() {
        XCTAssertEqual(settings.excludedBundleIDs, [])
    }

    func testDefaultLaunchAtLoginIsTrue() {
        XCTAssertTrue(settings.launchAtLogin)
    }

    func testDefaultOnboardingStateIsUnknown() {
        XCTAssertEqual(settings.onboardingState, .unknown)
    }

    // MARK: - Read / Write

    func testWriteAndReadHotkeyKeyCode() {
        settings.hotkeyKeyCode = 42
        XCTAssertEqual(settings.hotkeyKeyCode, 42)
    }

    func testWriteAndReadHotkeyModifiers() {
        let mods: UInt64 = 0x100000 | 0x040000  // cmd + ctrl
        settings.hotkeyModifiers = mods
        XCTAssertEqual(settings.hotkeyModifiers, mods)
    }

    func testWriteAndReadMaxHistoryCount() {
        settings.maxHistoryCount = 1000
        XCTAssertEqual(settings.maxHistoryCount, 1000)
    }

    func testWriteAndReadAutoPurgeAgeDays() {
        settings.autoPurgeAgeDays = 30
        XCTAssertEqual(settings.autoPurgeAgeDays, 30)
    }

    func testWriteAndReadExcludedBundleIDs() {
        let ids = ["com.apple.Safari", "com.googlecode.iterm2"]
        settings.excludedBundleIDs = ids
        XCTAssertEqual(settings.excludedBundleIDs, ids)
    }

    func testWriteAndReadLaunchAtLogin() {
        settings.launchAtLogin = true
        XCTAssertTrue(settings.launchAtLogin)
        settings.launchAtLogin = false
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testWriteAndReadOnboardingState() {
        settings.onboardingState = .pending
        XCTAssertEqual(settings.onboardingState, .pending)

        settings.onboardingState = .completed
        XCTAssertEqual(settings.onboardingState, .completed)
    }

    // MARK: - Overrides persist

    func testHotkeyKeyCodeOverrideDoesNotFallBackToDefault() {
        // Writing a non-zero value should persist it, not fall back to default
        settings.hotkeyKeyCode = 10
        XCTAssertEqual(settings.hotkeyKeyCode, 10)
    }

    func testMaxHistoryCountOverrideDoesNotFallBackToDefault() {
        settings.maxHistoryCount = 100
        XCTAssertEqual(settings.maxHistoryCount, 100)
    }

    func testAutoPurgeAgeDaysOverrideDoesNotFallBackToDefault() {
        settings.autoPurgeAgeDays = 7
        XCTAssertEqual(settings.autoPurgeAgeDays, 7)
    }

    func testOnboardingStateResolvesToPendingForFreshInstall() {
        XCTAssertEqual(
            Settings.OnboardingState.resolvedForLaunch(current: .unknown, hasExistingData: false),
            .pending
        )
    }

    func testOnboardingStateResolvesToCompletedForExistingInstall() {
        XCTAssertEqual(
            Settings.OnboardingState.resolvedForLaunch(current: .unknown, hasExistingData: true),
            .completed
        )
    }

    // MARK: - Ask AI Tools flags

    func testAskAIToolFlagsDefaultToDisabled() {
        XCTAssertFalse(settings.askAIWebSearchEnabled)
        XCTAssertFalse(settings.claudeCodeHistoryToolEnabled)
        XCTAssertFalse(settings.codexHistoryToolEnabled)
    }

    func testWriteAndReadAskAIWebSearchEnabled() {
        settings.askAIWebSearchEnabled = true
        XCTAssertTrue(settings.askAIWebSearchEnabled)
        settings.askAIWebSearchEnabled = false
        XCTAssertFalse(settings.askAIWebSearchEnabled)
    }

    func testWriteAndReadClaudeCodeHistoryToolEnabled() {
        settings.claudeCodeHistoryToolEnabled = true
        XCTAssertTrue(settings.claudeCodeHistoryToolEnabled)
        settings.claudeCodeHistoryToolEnabled = false
        XCTAssertFalse(settings.claudeCodeHistoryToolEnabled)
    }

    func testWriteAndReadCodexHistoryToolEnabled() {
        settings.codexHistoryToolEnabled = true
        XCTAssertTrue(settings.codexHistoryToolEnabled)
        settings.codexHistoryToolEnabled = false
        XCTAssertFalse(settings.codexHistoryToolEnabled)
    }
}
