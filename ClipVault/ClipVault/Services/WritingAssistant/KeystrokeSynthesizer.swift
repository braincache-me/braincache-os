import AppKit
import CoreGraphics

/// Synthesises keyboard events for the Writing Assistant — firing ⌘A / ⌘V to
/// replace a field's contents during a smart rewrite.
final class KeystrokeSynthesizer {

    /// ANSI virtual key codes used by the assistant.
    enum VirtualKey {
        static let a: CGKeyCode = 0x00
        static let c: CGKeyCode = 0x08
        static let v: CGKeyCode = 0x09
        static let rightArrow: CGKeyCode = 0x7C
    }

    private let source = CGEventSource(stateID: .combinedSessionState)

    // MARK: - Public API

    /// Sends ⌘A (select all) to the target.
    func selectAll(pid: pid_t?) {
        postCombo(virtualKey: VirtualKey.a, flags: .maskCommand, pid: pid)
    }

    /// Sends ⌘C (copy) to the target.
    func copy(pid: pid_t?) {
        postCombo(virtualKey: VirtualKey.c, flags: .maskCommand, pid: pid)
    }

    /// Sends ⌘V (paste) to the target.
    func paste(pid: pid_t?) {
        postCombo(virtualKey: VirtualKey.v, flags: .maskCommand, pid: pid)
    }

    /// Sends Right Arrow to collapse a selection to its trailing edge before appending.
    func moveRight(pid: pid_t?) {
        postCombo(virtualKey: VirtualKey.rightArrow, flags: [], pid: pid)
    }

    // MARK: - Internals

    private func postCombo(virtualKey: CGKeyCode, flags: CGEventFlags, pid: pid_t?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        post(down, pid: pid); post(up, pid: pid)
    }

    private func post(_ event: CGEvent, pid: pid_t?) {
        if let pid, pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}
