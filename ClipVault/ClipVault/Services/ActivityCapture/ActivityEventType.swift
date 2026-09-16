import Foundation

/// The type of a recorded UI activity event.
enum ActivityEventType: String, Codable, CaseIterable {
    // MARK: - Mouse events
    /// A left mouse button click.
    case leftClick = "left_click"
    /// A right mouse button click.
    case rightClick = "right_click"
    /// Another mouse button click (middle, etc.).
    case otherClick = "other_click"

    // MARK: - Keyboard events
    /// A keyboard shortcut (modifier + key). Raw text is never stored.
    case keyShortcut = "key_shortcut"
    /// Consolidated text input from the keyboard (buffered and merged).
    case textInput = "text_input"

    // MARK: - Focus / app-switch events
    /// The frontmost app changed.
    case appActivated = "app_activated"
    /// The focused window changed within the same app.
    case windowFocused = "window_focused"
    /// The title of the current window changed.
    case windowTitleChanged = "window_title_changed"

    // MARK: - Idle / timer events
    /// The user returned from idle.
    case idleResumed = "idle_resumed"
    /// A periodic fallback capture was triggered.
    case periodicCapture = "periodic_capture"

    // MARK: - Screenshot events
    /// A screenshot was captured (may be standalone or attached to another event).
    case screenshotCaptured = "screenshot_captured"

    // MARK: - Meeting audio recording events
    /// A meeting audio recording started (mic activity detected by another app).
    case meetingRecordingStarted = "meeting_recording_started"
    /// A meeting audio recording stopped (mic went inactive).
    case meetingRecordingStopped = "meeting_recording_stopped"

    // MARK: - Meeting transcription events
    /// A meeting transcript capture started (mic activity detected by another app).
    case meetingTranscriptStarted = "meeting_transcript_started"
    /// A meeting transcript capture stopped (mic went inactive); the transcript
    /// file path is on the event's `transcriptPath`.
    case meetingTranscriptStopped = "meeting_transcript_stopped"

    // MARK: - AI Assist
    /// A user-initiated AI Assist roundtrip: voice prompt + (optional) window
    /// screenshot in, streamed AI response out. Logged so the day's
    /// transcripts and the responses they produced sit side-by-side in the
    /// activity history.
    case aiAssistResponse = "ai_assist_response"

    // MARK: - Session lifecycle
    /// Recording session started.
    case sessionStarted = "session_started"
    /// Recording session stopped.
    case sessionStopped = "session_stopped"
    /// Recording session paused by the user.
    case sessionPaused = "session_paused"
    /// Recording session resumed by the user.
    case sessionResumed = "session_resumed"
}
