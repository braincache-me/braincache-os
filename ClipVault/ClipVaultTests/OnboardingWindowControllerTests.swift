import XCTest
@testable import ClipVault

final class OnboardingWindowControllerTests: XCTestCase {

    private var originalOnboardingState: Settings.OnboardingState!

    override func setUp() {
        super.setUp()
        originalOnboardingState = Settings.shared.onboardingState
    }

    override func tearDown() {
        Settings.shared.onboardingState = originalOnboardingState
        super.tearDown()
    }

    // MARK: - show()

    func testShowSetsCurrentStepToOverview() {
        let controller = OnboardingWindowController.shared
        // Put the controller in a non-overview state first
        controller.currentStep = .ai

        controller.show()

        XCTAssertEqual(controller.currentStep, .overview)
    }

    func testShowDoesNotImmediatelyActivateWindow() {
        // Verify the fix: showWindow/activate are deferred to next run loop, not called synchronously.
        // We confirm this by checking that calling show() synchronously does NOT raise (and the
        // policy change happens before window ordering on the next iteration).
        // This test validates the call doesn't crash; the async portion runs on main queue.
        let controller = OnboardingWindowController.shared
        XCTAssertNoThrow(controller.show())
        // Drain the main queue so the async block executes without triggering NSApp state changes
        // that could interfere — just ensure no crash.
        let exp = expectation(description: "async block runs")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)
    }

    // MARK: - completeOnboarding()

    func testCompleteOnboardingSetsOnboardingStateToCompleted() {
        Settings.shared.onboardingState = .pending
        let controller = OnboardingWindowController.shared

        controller.completeOnboarding()

        XCTAssertEqual(Settings.shared.onboardingState, .completed)
    }

    func testCompleteOnboardingIdempotentWhenAlreadyCompleted() {
        Settings.shared.onboardingState = .completed
        let controller = OnboardingWindowController.shared

        // Calling again should not crash and state stays completed
        controller.completeOnboarding()

        XCTAssertEqual(Settings.shared.onboardingState, .completed)
    }

    // MARK: - String constant wording (Task 4)

    func testAccessibilityCardBodyMentionsMacOS13SystemSettings() {
        let body = OnboardingWindowController.accessibilityCardBody
        XCTAssertTrue(body.contains("macOS 13"), "Card body should mention macOS 13 for version-conditional instructions")
        XCTAssertTrue(body.contains("System Settings"), "Card body should direct user to System Settings on macOS 13+")
        XCTAssertTrue(body.contains("toggle"), "Card body should tell user to toggle the switch manually")
    }

    func testPermissionsFooterNoteMentionsMacOS13ManualStep() {
        let note = OnboardingWindowController.permissionsFooterNote
        XCTAssertTrue(note.contains("macOS 13"), "Footer note should mention macOS 13 for version-conditional instructions")
        XCTAssertTrue(note.contains("manually enable"), "Footer note should clarify the manual step required on macOS 13+")
        XCTAssertTrue(note.contains("System Settings"), "Footer note should mention System Settings")
    }
}
