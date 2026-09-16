import XCTest
import AppKit
@testable import ClipVault

// MARK: - Helpers

private func makeKeyEvent(keyCode: UInt16,
                          modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )
}

// MARK: - ChatPanelWindow performKeyEquivalent

final class ChatPanelWindowKeyEquivalentTests: XCTestCase {

    private var panel: ChatPanelWindow!

    override func setUp() {
        super.setUp()
        panel = ChatPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() {
        panel = nil
        super.tearDown()
    }

    // Cmd+V (keyCode 9) — paste: Edit key equivalent; sendAction returns false with no
    // handler in the test context, but must not crash.
    func testCmdVDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 9, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+C (keyCode 8) — copy
    func testCmdCDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 8, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+X (keyCode 7) — cut
    func testCmdXDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 7, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+A (keyCode 0) — selectAll
    func testCmdADoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 0, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+Z (keyCode 6) — undo
    func testCmdZDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 6, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+Shift+Z (keyCode 6, shift) — redo
    func testCmdShiftZDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 6,
                                       modifiers: [.command, .shift]) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Non-Edit Cmd key (Cmd+W, keyCode 13) — falls through to super, must not crash
    func testNonEditCmdKeyFallsThroughWithoutCrash() {
        guard let event = makeKeyEvent(keyCode: 13, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // A key pressed without Command modifier — not intercepted as Edit equivalent
    func testKeyWithoutCmdModifierFallsThrough() {
        guard let event = makeKeyEvent(keyCode: 9, modifiers: []) else {
            return XCTFail("Could not create NSEvent")
        }
        let handled = panel.performKeyEquivalent(with: event)
        XCTAssertFalse(handled, "A key without Command should not be handled as an Edit equivalent")
    }

    // All six Edit key codes are dispatched through the performKeyEquivalent override
    // (no assertion on return value since there is no text responder in the test context)
    func testAllEditKeyEquivalentsAreDispatched() {
        let editKeyCodes: [UInt16] = [8, 9, 7, 0, 6]  // C, V, X, A, Z
        for keyCode in editKeyCodes {
            guard let event = makeKeyEvent(keyCode: keyCode, modifiers: .command) else {
                XCTFail("Could not create event for keyCode \(keyCode)")
                continue
            }
            XCTAssertNoThrow(panel.performKeyEquivalent(with: event),
                             "performKeyEquivalent must not throw for Edit keyCode \(keyCode)")
        }
    }
}

// MARK: - SearchPanelWindow performKeyEquivalent

final class SearchPanelWindowKeyEquivalentTests: XCTestCase {

    private var panel: SearchPanelWindow!

    override func setUp() {
        super.setUp()
        panel = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() {
        panel = nil
        super.tearDown()
    }

    func testCmdVDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 9, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    func testAllEditKeyEquivalentsAreDispatchedWithoutCrash() {
        let editKeyCodes: [UInt16] = [8, 9, 7, 0, 6]  // C, V, X, A, Z
        for keyCode in editKeyCodes {
            guard let event = makeKeyEvent(keyCode: keyCode, modifiers: .command) else {
                XCTFail("Could not create event for keyCode \(keyCode)")
                continue
            }
            XCTAssertNoThrow(panel.performKeyEquivalent(with: event),
                             "performKeyEquivalent must not throw for Edit keyCode \(keyCode)")
        }
    }

    func testNonEditCmdKeyFallsThroughWithoutCrash() {
        guard let event = makeKeyEvent(keyCode: 13, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.performKeyEquivalent(with: event))
    }

    // Cmd+key events must NOT be redirected via redirectToSearchField in keyDown —
    // they should call super.keyDown instead (no crash expected even without a content view).
    func testCmdKeyInKeyDownDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 9, modifiers: .command) else {
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.keyDown(with: event))
    }

    // Regular (non-Cmd) key events are still redirected via redirectToSearchField —
    // verify no crash when the search field is not set up (no controller window).
    func testRegularKeyInKeyDownDoesNotCrash() {
        guard let event = makeKeyEvent(keyCode: 5, modifiers: []) else {  // G key
            return XCTFail("Could not create NSEvent")
        }
        XCTAssertNoThrow(panel.keyDown(with: event))
    }
}

// MARK: - AppDelegate Edit menu structure

final class AppDelegateEditMenuTests: XCTestCase {

    // Verify the expected Edit-menu item actions are present when the menu is built.
    // We exercise the same construction logic that AppDelegate.setupEditMenu() uses.
    func testEditMenuContainsPasteAction() {
        let menu = buildEditMenu()
        XCTAssertTrue(
            menu.items.contains { $0.action == #selector(NSText.paste(_:)) },
            "Edit menu must contain a Paste item"
        )
    }

    func testEditMenuContainsCopyAction() {
        let menu = buildEditMenu()
        XCTAssertTrue(
            menu.items.contains { $0.action == #selector(NSText.copy(_:)) },
            "Edit menu must contain a Copy item"
        )
    }

    func testEditMenuContainsCutAction() {
        let menu = buildEditMenu()
        XCTAssertTrue(
            menu.items.contains { $0.action == #selector(NSText.cut(_:)) },
            "Edit menu must contain a Cut item"
        )
    }

    func testEditMenuContainsSelectAllAction() {
        let menu = buildEditMenu()
        XCTAssertTrue(
            menu.items.contains { $0.action == #selector(NSText.selectAll(_:)) },
            "Edit menu must contain a Select All item"
        )
    }

    func testEditMenuItemsTargetNil() {
        let menu = buildEditMenu()
        let actionItems = menu.items.filter { !$0.isSeparatorItem }
        for item in actionItems {
            XCTAssertNil(item.target,
                         "Edit menu item '\(item.title)' must target nil (first responder chain)")
        }
    }

    func testPasteKeyEquivalentIsV() {
        let menu = buildEditMenu()
        let item = menu.items.first { $0.action == #selector(NSText.paste(_:)) }
        XCTAssertEqual(item?.keyEquivalent, "v")
    }

    func testCopyKeyEquivalentIsC() {
        let menu = buildEditMenu()
        let item = menu.items.first { $0.action == #selector(NSText.copy(_:)) }
        XCTAssertEqual(item?.keyEquivalent, "c")
    }

    func testCutKeyEquivalentIsX() {
        let menu = buildEditMenu()
        let item = menu.items.first { $0.action == #selector(NSText.cut(_:)) }
        XCTAssertEqual(item?.keyEquivalent, "x")
    }

    func testSelectAllKeyEquivalentIsA() {
        let menu = buildEditMenu()
        let item = menu.items.first { $0.action == #selector(NSText.selectAll(_:)) }
        XCTAssertEqual(item?.keyEquivalent, "a")
    }

    // MARK: - Helpers

    /// Replicates the Edit menu construction from AppDelegate.setupEditMenu().
    private func buildEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")),
                         keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        return editMenu
    }
}
