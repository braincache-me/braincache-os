import AppKit
import Sparkle

final class StatusMenuBuilder {

    /// Build the status-bar menu reflecting the given recorder state.
    func buildMenu(
        recorderState: ActivityCaptureState = .idle,
        voiceRecordingActive: Bool = false,
        voicePanelVisible: Bool = false
    ) -> NSMenu {
        let menu = NSMenu()

        // MARK: Standard items

        let about = NSMenuItem(
            title: "About BrainCache",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        menu.addItem(about)

        let preferences = NSMenuItem(
            title: "Preferences\u{2026}",
            action: #selector(AppDelegate.openPreferences),
            keyEquivalent: ","
        )
        preferences.target = NSApp.delegate as? AppDelegate
        menu.addItem(preferences)

        // Routed through AppDelegate so the app can activate before Sparkle
        // opens its window (LSUIElement = true otherwise leaves the window
        // behind the frontmost app).
        if let appDelegate = NSApp.delegate as? AppDelegate, appDelegate.updaterController != nil {
            let checkForUpdates = NSMenuItem(
                title: "Check for Updates\u{2026}",
                action: #selector(AppDelegate.checkForUpdatesAction(_:)),
                keyEquivalent: ""
            )
            checkForUpdates.target = appDelegate
            menu.addItem(checkForUpdates)
        }

        let chat = NSMenuItem(
            title: "Chat with Data",
            action: Settings.shared.isAIEnabled ? #selector(AppDelegate.openChatPanel) : nil,
            keyEquivalent: ""
        )
        chat.target = NSApp.delegate as? AppDelegate
        menu.addItem(chat)

        let rewrite = NSMenuItem(
            title: "Open Writing Assistant",
            action: Settings.shared.isAIEnabled ? #selector(AppDelegate.triggerAIRewriteAction) : nil,
            keyEquivalent: ""
        )
        rewrite.target = NSApp.delegate as? AppDelegate
        rewrite.toolTip = "Opens the writing assistant below the focused text cursor."
        menu.addItem(rewrite)

        // MARK: Voice Recording controls

        menu.addItem(.separator())

        if voiceRecordingActive {
            let status = NSMenuItem(
                title: voicePanelVisible ? "Voice Recording…" : "Voice Recording (panel hidden)…",
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)

            if !voicePanelVisible {
                let showPanel = NSMenuItem(
                    title: "Show Voice Recording Panel",
                    action: #selector(AppDelegate.showVoiceRecordingPanelAction),
                    keyEquivalent: ""
                )
                showPanel.target = NSApp.delegate as? AppDelegate
                menu.addItem(showPanel)
            }

            let stopVoice = NSMenuItem(
                title: "Stop Voice Recording",
                action: #selector(AppDelegate.stopVoiceRecordingAction),
                keyEquivalent: ""
            )
            stopVoice.target = NSApp.delegate as? AppDelegate
            menu.addItem(stopVoice)
        } else {
            let start = NSMenuItem(
                title: "Start Voice Recording",
                action: #selector(AppDelegate.startVoiceRecordingAction),
                keyEquivalent: ""
            )
            start.target = NSApp.delegate as? AppDelegate
            menu.addItem(start)

            let startWithSys = NSMenuItem(
                title: "Start Voice Recording with System Audio",
                action: #selector(AppDelegate.startVoiceRecordingWithSystemAudioAction),
                keyEquivalent: ""
            )
            startWithSys.target = NSApp.delegate as? AppDelegate
            menu.addItem(startWithSys)
        }

        menu.addItem(.separator())

        // MARK: Activity Capture controls

        let start = NSMenuItem(
            title: "Start Activity Capture",
            action: recorderState == .idle ? #selector(AppDelegate.startActivityCaptureAction) : nil,
            keyEquivalent: ""
        )
        start.target = NSApp.delegate as? AppDelegate
        menu.addItem(start)

        let pauseTitle = recorderState == .paused
            ? "Resume Activity Capture"
            : "Pause Activity Capture"
        let pauseAction: Selector?
        switch recorderState {
        case .idle:
            pauseAction = nil
        case .recording:
            pauseAction = #selector(AppDelegate.pauseActivityCaptureAction)
        case .paused:
            pauseAction = #selector(AppDelegate.resumeActivityCaptureAction)
        }
        let pauseResume = NSMenuItem(title: pauseTitle, action: pauseAction, keyEquivalent: "")
        pauseResume.target = NSApp.delegate as? AppDelegate
        menu.addItem(pauseResume)

        let stop = NSMenuItem(
            title: "Stop Activity Capture",
            action: recorderState != .idle ? #selector(AppDelegate.stopActivityCaptureAction) : nil,
            keyEquivalent: ""
        )
        stop.target = NSApp.delegate as? AppDelegate
        menu.addItem(stop)

        menu.addItem(.separator())

        // MARK: Activity History

        let history = NSMenuItem(
            title: "Activity History\u{2026}",
            action: #selector(AppDelegate.openActivityHistory),
            keyEquivalent: "h"
        )
        history.keyEquivalentModifierMask = [.option, .command]
        history.target = NSApp.delegate as? AppDelegate
        menu.addItem(history)

        menu.addItem(.separator())

        // MARK: Quit

        let quit = NSMenuItem(
            title: "Quit BrainCache",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }
}

// MARK: - AppDelegate actions

extension AppDelegate {
    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc func openChatPanel() {
        ChatPanelController.shared.toggle()
    }

    @objc func openActivityHistory() {
        ActivityHistoryWindowController.shared.show()
    }

    /// Triggers the writing assistant from the status menu.
    /// Dispatched async so the menu fully dismisses and the previous app
    /// regains focus before we read its focused element.
    @objc func triggerAIRewriteAction() {
        DispatchQueue.main.async { [weak self] in
            _ = self?.writingCoordinator.handleRewriteHotkey()
        }
    }
}
