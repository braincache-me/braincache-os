import AppKit
import Carbon.HIToolbox

// MARK: - KeyRecorderView

/// A simple key-recorder button that captures the next key event when focused.
final class KeyRecorderView: NSControl {

    enum Binding {
        case search
        case chat
        case voice
        case voiceRewrite
        case aiRewrite
    }

    var binding: Binding = .search

    private let label = NSTextField(labelWithString: "Click to record…")
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Display

    func setHotkey(keyCode: Int, modifiers: UInt64) {
        label.stringValue = Self.humanReadable(keyCode: keyCode, modifiers: modifiers)
        isRecording = false
    }

    // MARK: - Mouse / Key

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        label.stringValue = "Type shortcut…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Ignore standalone modifiers (left- and right-side variants)
        let modifierKeyCodes: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_Command), UInt16(kVK_Option), UInt16(kVK_Control),
            UInt16(kVK_RightShift), UInt16(kVK_RightCommand), UInt16(kVK_RightOption), UInt16(kVK_RightControl),
            UInt16(kVK_CapsLock), UInt16(kVK_Function),
        ]
        if modifierKeyCodes.contains(event.keyCode) || event.keyCode == UInt16(kVK_Escape) {
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                layer?.borderColor = NSColor.separatorColor.cgColor
                // Restore current value display
                let (kc, mods) = currentHotkey()
                setHotkey(keyCode: kc, modifiers: mods)
            }
            return
        }

        let carbonFlags = cgEventFlags(from: event.modifierFlags)
        let keyCode = Int(event.keyCode)

        switch binding {
        case .search:
            Settings.shared.hotkeyKeyCode = keyCode
            Settings.shared.hotkeyModifiers = carbonFlags
        case .chat:
            Settings.shared.chatHotkeyKeyCode = keyCode
            Settings.shared.chatHotkeyModifiers = carbonFlags
        case .voice:
            Settings.shared.voiceHotkeyKeyCode = keyCode
            Settings.shared.voiceHotkeyModifiers = carbonFlags
        case .voiceRewrite:
            Settings.shared.voiceRewriteHotkeyKeyCode = keyCode
            Settings.shared.voiceRewriteHotkeyModifiers = carbonFlags
        case .aiRewrite:
            Settings.shared.aiRewriteHotkeyKeyCode = keyCode
            Settings.shared.aiRewriteHotkeyModifiers = carbonFlags
        }

        setHotkey(keyCode: keyCode, modifiers: carbonFlags)
        layer?.borderColor = NSColor.separatorColor.cgColor

        // Notify target/action
        sendAction(action, to: target)
    }

    private func currentHotkey() -> (Int, UInt64) {
        switch binding {
        case .search: return (Settings.shared.hotkeyKeyCode, Settings.shared.hotkeyModifiers)
        case .chat:   return (Settings.shared.chatHotkeyKeyCode, Settings.shared.chatHotkeyModifiers)
        case .voice:  return (Settings.shared.voiceHotkeyKeyCode, Settings.shared.voiceHotkeyModifiers)
        case .voiceRewrite:
            return (Settings.shared.voiceRewriteHotkeyKeyCode, Settings.shared.voiceRewriteHotkeyModifiers)
        case .aiRewrite:
            return (Settings.shared.aiRewriteHotkeyKeyCode, Settings.shared.aiRewriteHotkeyModifiers)
        }
    }

    // MARK: - Helpers

    private func cgEventFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var result: UInt64 = 0
        if flags.contains(.command)  { result |= 0x100000 }
        if flags.contains(.shift)    { result |= 0x020000 }
        if flags.contains(.option)   { result |= 0x080000 }
        if flags.contains(.control)  { result |= 0x040000 }
        return result
    }

    static func humanReadable(keyCode: Int, modifiers: UInt64) -> String {
        var result = ""
        if modifiers & 0x040000 != 0 { result += "⌃" }
        if modifiers & 0x080000 != 0 { result += "⌥" }
        if modifiers & 0x020000 != 0 { result += "⇧" }
        if modifiers & 0x100000 != 0 { result += "⌘" }

        let keyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        result += keyNames[keyCode] ?? "Key(\(keyCode))"
        return result
    }
}

// MARK: - HotkeyPrefsView

final class HotkeyPrefsView: NSView {

    private let searchRecorder = KeyRecorderView()
    private let voiceRecorder = KeyRecorderView()
    private let voiceRewriteRecorder = KeyRecorderView()
    private let aiRewriteRecorder = KeyRecorderView()
    private let descriptionLabel = NSTextField(
        labelWithString: "Click the box and type your preferred shortcut.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        refreshDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func buildUI() {
        let searchTitle = NSTextField(labelWithString: "Search Hotkey:")
        searchTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        searchRecorder.binding = .search
        searchRecorder.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        searchRecorder.target = self
        searchRecorder.action = #selector(hotkeyChanged)

        let voiceTitle = NSTextField(labelWithString: "Voice Transcription Hotkey:")
        voiceTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        voiceRecorder.binding = .voice
        voiceRecorder.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        voiceRecorder.target = self
        voiceRecorder.action = #selector(hotkeyChanged)

        let voiceRewriteTitle = NSTextField(labelWithString: "Voice + AI Rewrite Hotkey:")
        voiceRewriteTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let voiceRewriteSubtitle = NSTextField(labelWithString:
            "Records, then runs the transcript through an LLM to fix grammar and transcription errors before pasting.")
        voiceRewriteSubtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        voiceRewriteSubtitle.textColor = .secondaryLabelColor
        voiceRewriteSubtitle.maximumNumberOfLines = 2
        voiceRewriteSubtitle.lineBreakMode = .byWordWrapping

        voiceRewriteRecorder.binding = .voiceRewrite
        voiceRewriteRecorder.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        voiceRewriteRecorder.target = self
        voiceRewriteRecorder.action = #selector(hotkeyChanged)

        let aiRewriteTitle = NSTextField(labelWithString: "AI Rewrite Hotkey:")
        aiRewriteTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let aiRewriteSubtitle = NSTextField(labelWithString:
            "Rewrites the focused text field (or selection) through the LLM. No voice — text only.")
        aiRewriteSubtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiRewriteSubtitle.textColor = .secondaryLabelColor
        aiRewriteSubtitle.maximumNumberOfLines = 2
        aiRewriteSubtitle.lineBreakMode = .byWordWrapping

        aiRewriteRecorder.binding = .aiRewrite
        aiRewriteRecorder.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        aiRewriteRecorder.target = self
        aiRewriteRecorder.action = #selector(hotkeyChanged)

        for view in [searchTitle, searchRecorder, voiceTitle, voiceRecorder, voiceRewriteTitle, voiceRewriteSubtitle, voiceRewriteRecorder, aiRewriteTitle, aiRewriteSubtitle, aiRewriteRecorder, descriptionLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            searchTitle.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            searchTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            searchRecorder.topAnchor.constraint(equalTo: searchTitle.bottomAnchor, constant: 8),
            searchRecorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            searchRecorder.widthAnchor.constraint(equalToConstant: 200),
            searchRecorder.heightAnchor.constraint(equalToConstant: 28),

            voiceTitle.topAnchor.constraint(equalTo: searchRecorder.bottomAnchor, constant: 18),
            voiceTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            voiceRecorder.topAnchor.constraint(equalTo: voiceTitle.bottomAnchor, constant: 8),
            voiceRecorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            voiceRecorder.widthAnchor.constraint(equalToConstant: 200),
            voiceRecorder.heightAnchor.constraint(equalToConstant: 28),

            voiceRewriteTitle.topAnchor.constraint(equalTo: voiceRecorder.bottomAnchor, constant: 18),
            voiceRewriteTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            voiceRewriteSubtitle.topAnchor.constraint(equalTo: voiceRewriteTitle.bottomAnchor, constant: 4),
            voiceRewriteSubtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            voiceRewriteSubtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            voiceRewriteRecorder.topAnchor.constraint(equalTo: voiceRewriteSubtitle.bottomAnchor, constant: 6),
            voiceRewriteRecorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            voiceRewriteRecorder.widthAnchor.constraint(equalToConstant: 200),
            voiceRewriteRecorder.heightAnchor.constraint(equalToConstant: 28),

            aiRewriteTitle.topAnchor.constraint(equalTo: voiceRewriteRecorder.bottomAnchor, constant: 18),
            aiRewriteTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            aiRewriteSubtitle.topAnchor.constraint(equalTo: aiRewriteTitle.bottomAnchor, constant: 4),
            aiRewriteSubtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            aiRewriteSubtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            aiRewriteRecorder.topAnchor.constraint(equalTo: aiRewriteSubtitle.bottomAnchor, constant: 6),
            aiRewriteRecorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            aiRewriteRecorder.widthAnchor.constraint(equalToConstant: 200),
            aiRewriteRecorder.heightAnchor.constraint(equalToConstant: 28),

            descriptionLabel.topAnchor.constraint(equalTo: aiRewriteRecorder.bottomAnchor, constant: 12),
            descriptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
    }

    func refreshDisplay() {
        searchRecorder.setHotkey(keyCode: Settings.shared.hotkeyKeyCode,
                                 modifiers: Settings.shared.hotkeyModifiers)
        voiceRecorder.setHotkey(keyCode: Settings.shared.voiceHotkeyKeyCode,
                                modifiers: Settings.shared.voiceHotkeyModifiers)
        voiceRewriteRecorder.setHotkey(keyCode: Settings.shared.voiceRewriteHotkeyKeyCode,
                                       modifiers: Settings.shared.voiceRewriteHotkeyModifiers)
        aiRewriteRecorder.setHotkey(keyCode: Settings.shared.aiRewriteHotkeyKeyCode,
                                    modifiers: Settings.shared.aiRewriteHotkeyModifiers)
    }

    @objc private func hotkeyChanged() {
        // Re-register the hotkey with the new key combination
        // AppDelegate owns HotkeyManager; notify via notification so we don't create a coupling.
        NotificationCenter.default.post(name: .clipVaultHotkeyDidChange, object: nil)
    }
}

extension Notification.Name {
    static let clipVaultHotkeyDidChange = Notification.Name("com.yourname.ClipVault.hotkeyDidChange")
}
