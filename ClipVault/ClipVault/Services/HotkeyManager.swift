import AppKit
import Carbon.HIToolbox
import HotKey

/// Manages the global keyboard shortcut that toggles the search panel.
final class HotkeyManager {

    /// Called when the search-panel hotkey fires.
    var keyDownHandler: (() -> Void)?

    private var hotKey: HotKey?

    // MARK: - Registration

    /// Register (or re-register) the hotkey using the current Settings values.
    func register() {
        unregister()
        registerPrimary()
    }

    /// Register only the primary search-panel hotkey.
    func registerPrimary() {
        hotKey = nil
        let keyCode   = Settings.shared.hotkeyKeyCode
        let modifiers = Settings.shared.hotkeyModifiers
        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            NSLog("HotkeyManager: unknown carbon key code %d", keyCode)
            return
        }
        let flags = NSEvent.ModifierFlags(carbonFlags: modifiers)
        hotKey = HotKey(key: key, modifiers: flags)
        hotKey?.keyDownHandler = { [weak self] in
            self?.keyDownHandler?()
        }
    }

    /// Unregister the hotkey.
    func unregister() {
        hotKey = nil
    }
}

// MARK: - Helpers

private extension NSEvent.ModifierFlags {
    /// Build NSEvent.ModifierFlags from the raw CGEventFlags bitmask stored in Settings.
    init(carbonFlags: UInt64) {
        var flags: NSEvent.ModifierFlags = []
        // CGEventFlags.maskCommand  = 0x100000
        if carbonFlags & 0x100000 != 0 { flags.insert(.command) }
        // CGEventFlags.maskShift    = 0x020000
        if carbonFlags & 0x020000 != 0 { flags.insert(.shift) }
        // CGEventFlags.maskAlternate = 0x080000
        if carbonFlags & 0x080000 != 0 { flags.insert(.option) }
        // CGEventFlags.maskControl  = 0x040000
        if carbonFlags & 0x040000 != 0 { flags.insert(.control) }
        self = flags
    }
}
