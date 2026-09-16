import AppKit
import XCTest
@testable import ClipVault

// MARK: - FocusedTextSnapshot logic

final class FocusedTextSnapshotTests: XCTestCase {

    private func snapshot(
        role: String? = "AXTextField",
        value: String,
        selectedText: String = "",
        selLoc: Int = 0,
        selLen: Int = 0,
        secure: Bool = false,
        editable: Bool = true
    ) -> FocusedTextSnapshot {
        FocusedTextSnapshot(
            role: role,
            value: value,
            selectedText: selectedText,
            selectionLocation: selLoc,
            selectionLength: selLen,
            isSecure: secure,
            isEditable: editable,
            pid: 0,
            bundleID: nil,
            appName: nil,
            windowTitle: nil,
            element: nil
        )
    }

    func testHasRewritableTextWithEditableNonEmptyField() {
        XCTAssertTrue(snapshot(value: "Hello").hasRewritableText)
    }

    func testHasRewritableTextFalseForBlankField() {
        XCTAssertFalse(snapshot(value: "   ").hasRewritableText)
        XCTAssertFalse(snapshot(value: "").hasRewritableText)
    }

    func testCanAttemptRewriteForEditableBlankField() {
        XCTAssertTrue(snapshot(value: "").canAttemptRewrite)
    }

    func testHasRewritableTextFalseForSecureField() {
        XCTAssertFalse(snapshot(value: "Hello", secure: true).hasRewritableText)
        XCTAssertFalse(snapshot(value: "Hello", secure: true).canAttemptRewrite)
    }

    func testHasRewritableTextFalseForNonEditableElement() {
        XCTAssertFalse(snapshot(value: "Hello", editable: false).hasRewritableText)
        XCTAssertFalse(snapshot(value: "Hello", editable: false).canAttemptRewrite)
    }

    func testTextToRewriteUsesSelectionWhenPresent() {
        let snap = snapshot(value: "Hello world", selectedText: "world", selLoc: 6, selLen: 5)
        XCTAssertTrue(snap.hasSelection)
        XCTAssertEqual(snap.textToRewrite, "world")
    }

    func testTextToRewriteUsesWholeFieldWhenNoSelection() {
        let snap = snapshot(value: "Hello world")
        XCTAssertFalse(snap.hasSelection)
        XCTAssertEqual(snap.textToRewrite, "Hello world")
    }

    func testRewritePromptIncludesAppNameAndWindowTitle() {
        var snap = snapshot(value: "Hello world")
        snap.appName = "Mail"
        snap.windowTitle = "Draft: Launch notes"

        let prompt = TextRewriteService.rewriteUserPrompt(sourceText: "Hello world", snapshot: snap)

        XCTAssertTrue(prompt.contains("App name: Mail"))
        XCTAssertTrue(prompt.contains("Window title: Draft: Launch notes"))
        XCTAssertTrue(prompt.contains("Hello world"))
    }

    func testAssistantPromptIncludesInstructionAndFocusedInput() {
        var snap = snapshot(value: "pwd")
        snap.appName = "Terminal"
        snap.windowTitle = "zsh"

        let prompt = TextRewriteService.assistantUserPrompt(
            instruction: "command to show all in folder",
            sourceText: snap.textToRewrite,
            snapshot: snap
        )

        XCTAssertTrue(prompt.contains("USER INSTRUCTION"))
        XCTAssertTrue(prompt.contains("command to show all in folder"))
        XCTAssertTrue(prompt.contains("CURRENT FOCUSED INPUT"))
        XCTAssertTrue(prompt.contains("pwd"))
        XCTAssertTrue(prompt.contains("terminal or shell"))
    }
}

// MARK: - Rich text replacement

final class RichTextRewritePayloadTests: XCTestCase {

    func testReplacementAttributedStringMapsStyleRunsOntoRewrittenText() {
        let source = NSMutableAttributedString(string: "Bold plain")
        source.addAttribute(.font,
                            value: NSFont.boldSystemFont(ofSize: 13),
                            range: NSRange(location: 0, length: 4))
        source.addAttribute(.font,
                            value: NSFont.systemFont(ofSize: 13),
                            range: NSRange(location: 5, length: 5))

        let rewritten = RichTextRewritePayload.replacementAttributedString(
            preservingStylesFrom: source,
            rewrittenText: "Strong simple text"
        )

        let firstFont = rewritten.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let lastFont = rewritten.attribute(.font, at: rewritten.length - 1, effectiveRange: nil) as? NSFont
        XCTAssertTrue(firstFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertFalse(lastFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }
}

// MARK: - AXGeometry

final class AXGeometryTests: XCTestCase {

    func testCocoaRectConversionIsItsOwnInverse() {
        // The vertical flip about the primary screen height is an involution:
        // converting twice must return the original rect, regardless of the
        // screen height the test machine happens to have.
        let original = CGRect(x: 120, y: 64, width: 8, height: 18)
        let once = AXGeometry.cocoaRect(fromAXRect: original)
        let twice = AXGeometry.cocoaRect(fromAXRect: once)
        XCTAssertEqual(twice, original)
    }

    func testCocoaRectPreservesSizeAndX() {
        let axRect = CGRect(x: 200, y: 300, width: 12, height: 20)
        let converted = AXGeometry.cocoaRect(fromAXRect: axRect)
        XCTAssertEqual(converted.origin.x, 200)
        XCTAssertEqual(converted.width, 12)
        XCTAssertEqual(converted.height, 20)
    }

    func testCaretXUsesCharacterMaxXForNormalBounds() {
        let rect = CGRect(x: 100, y: 20, width: 9, height: 20)
        XCTAssertEqual(FocusedTextReader.caretX(forCharacterBounds: rect), 109)
    }

    func testCaretXCapsOversizedCharacterBounds() {
        let rect = CGRect(x: 100, y: 20, width: 44, height: 28)
        XCTAssertEqual(FocusedTextReader.caretX(forCharacterBounds: rect), 115.4, accuracy: 0.01)
    }
}

// MARK: - Prompts

final class WritingAssistantPromptsTests: XCTestCase {

    func testWritingAssistantPromptsLoad() {
        XCTAssertFalse(Prompts.shared.writingAssistant.rewriteSystem.isEmpty)
    }
}

// MARK: - Settings round-trip

final class WritingAssistantSettingsTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "WritingAssistantSettingsTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    func testRewritePromptDefaultsToBundledPrompt() {
        XCTAssertEqual(settings.writingRewritePrompt,
                       Prompts.shared.writingAssistant.rewriteSystem)
    }

    func testCustomRewritePromptPersists() {
        settings.writingRewritePrompt = "Make it sound like a pirate."
        XCTAssertEqual(settings.writingRewritePrompt, "Make it sound like a pirate.")
    }

    func testBlankPromptFallsBackToDefault() {
        settings.writingRewritePrompt = "Custom"
        settings.writingRewritePrompt = "   "
        XCTAssertEqual(settings.writingRewritePrompt,
                       Prompts.shared.writingAssistant.rewriteSystem)
    }

    func testModelDefaultsToChatModel() {
        XCTAssertEqual(settings.writingRewriteModel, settings.chatModel)
    }

    func testCustomModelPersists() {
        settings.writingRewriteModel = "gpt-5.4-mini"
        XCTAssertEqual(settings.writingRewriteModel, "gpt-5.4-mini")
    }

    func testMaxOutputTokensDefaultsToRewriteCap() {
        XCTAssertEqual(settings.writingRewriteMaxOutputTokens, 4096)
    }

    func testCustomMaxOutputTokensPersists() {
        settings.writingRewriteMaxOutputTokens = 2048
        XCTAssertEqual(settings.writingRewriteMaxOutputTokens, 2048)
    }

    func testMaxOutputTokensClampsToSupportedRange() {
        settings.writingRewriteMaxOutputTokens = 10
        XCTAssertEqual(settings.writingRewriteMaxOutputTokens, 256)

        settings.writingRewriteMaxOutputTokens = 99_999
        XCTAssertEqual(settings.writingRewriteMaxOutputTokens, 32_000)
    }

}
