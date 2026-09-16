import Foundation

extension Notification.Name {
    /// Posted when activity capture is enabled or disabled.
    static let activityCaptureEnabledDidChange = Notification.Name("activityCaptureEnabledDidChange")

    /// Posted when activity capture is paused or resumed.
    static let activityCapturePausedDidChange = Notification.Name("activityCapturePausedDidChange")

    /// Posted when any activity capture setting (screenshots, quality, scale, intervals, etc.) changes.
    static let activityCaptureSettingsDidChange = Notification.Name("activityCaptureSettingsDidChange")

    /// Posted when the activity log root folder bookmark is updated (folder changed).
    static let activityCaptureLogRootDidChange = Notification.Name("activityCaptureLogRootDidChange")

    /// Posted when the excluded bundle IDs list changes.
    static let activityCaptureExclusionsDidChange = Notification.Name("activityCaptureExclusionsDidChange")
}
