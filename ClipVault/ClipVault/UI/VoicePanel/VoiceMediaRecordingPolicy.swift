import Foundation

/// Pure decision rules behind the voice panel's "Save recording" checkbox.
/// Kept free of AppKit so the state machine is unit-testable.
enum VoiceMediaRecordingPolicy {

    enum Action: Equatable {
        /// A session is live: start writing the file right now.
        case startNow
        /// Finalise the file being written.
        case stopNow
        /// No session yet: remember the wish and start with the next session.
        case arm
        /// Forget an armed wish.
        case disarm
        case none
    }

    /// What ticking / unticking the checkbox should do.
    static func action(checkboxOn: Bool, sessionRecording: Bool, mediaRecording: Bool) -> Action {
        switch (checkboxOn, sessionRecording, mediaRecording) {
        case (true, true, false): return .startNow
        case (true, true, true): return .none
        case (true, false, _): return .arm
        case (false, _, true): return .stopNow
        case (false, _, false): return .disarm
        }
    }

    /// The attached window may only change while no file is being written
    /// — it is the video source of that file.
    static func canChangeAttachedWindow(mediaRecording: Bool) -> Bool {
        !mediaRecording
    }
}
