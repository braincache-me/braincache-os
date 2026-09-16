import Foundation

/// A single recorded UI activity event.
///
/// Serializes to/from JSON Lines (JSONL) using ISO 8601 timestamps with millisecond precision.
/// All fields are designed to be human-readable and stable across app versions.
struct ActivityEvent: Codable, Equatable {

    // MARK: - Identity

    /// Unique identifier for this event (used for deduplication and correlation).
    let id: UUID

    /// When the event occurred, stored as ISO 8601 with millisecond precision.
    let timestamp: Date

    // MARK: - Application context

    /// The human-readable name of the frontmost application.
    let appName: String

    /// The bundle identifier of the frontmost application.
    let bundleID: String

    /// The title of the focused window at the time of the event.
    let windowTitle: String

    // MARK: - Event classification

    /// The type of event.
    let eventType: ActivityEventType

    // MARK: - Control metadata (may be nil for non-click events)

    /// The AX role of the interacted element, e.g. "AXButton", "AXTextField".
    let controlRole: String?

    /// The human-readable name or label of the interacted element.
    let controlName: String?

    /// The value of the interacted element (always nil for secure/password fields).
    let controlValue: String?

    // MARK: - Coordinates (nil for non-click events)

    /// Screen x-coordinate of the click, in points from top-left.
    let clickX: Double?

    /// Screen y-coordinate of the click, in points from top-left.
    let clickY: Double?

    /// Click x-coordinate relative to the focused window's top-left.
    /// Nil when the window frame could not be resolved.
    let windowClickX: Double?

    /// Click y-coordinate relative to the focused window's top-left.
    let windowClickY: Double?

    /// Text recognised via Vision OCR in a small region around the click, when
    /// AX metadata is missing or thin. Lets us label clicks in web content
    /// that doesn't expose an accessibility tree (Chrome without a11y enabled).
    let nearbyText: String?

    /// The URL of the active page when the event happened in a browser.
    /// Resolved from `kAXURLAttribute` on the focused `AXWebArea` ancestor.
    /// Nil for non-browser apps or when accessibility is not exposed.
    let url: String?

    // MARK: - Screenshot

    /// Relative path to the associated screenshot within the screenshots directory.
    /// E.g. `"2026-04-11/2026-04-11T14-23-45-123_Safari_app_activated.jpg"`.
    let screenshotPath: String?

    // MARK: - Audio recording

    /// Relative path to an associated audio recording within the recordings directory.
    /// E.g. `"2026-05-05/meeting_14-23-45.m4a"`.
    let audioPath: String?

    /// Relative path to an associated meeting transcript file within the transcripts directory.
    /// E.g. `"2026-05-05/transcript_14-23-45.txt"`.
    let transcriptPath: String?

    // MARK: - Internal deduplication / metadata

    /// An opaque identifier for the focused window, used for screenshot dedupe.
    let windowIdentifier: String?

    /// Free-form metadata about what triggered this event (e.g. the screenshot trigger type).
    let triggerMetadata: String?

    // MARK: - AI Assist (only set on `.aiAssistResponse` events)

    /// The voice transcript that was sent to the model.
    let aiPrompt: String?

    /// The streamed model response, captured at completion (or partial at error).
    let aiResponse: String?

    /// Human-readable summary of the window the user attached, if any.
    /// Format: "AppName — Window Title". Nil for no-attachment requests.
    let aiAttachedWindow: String?

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String,
        bundleID: String,
        windowTitle: String,
        eventType: ActivityEventType,
        controlRole: String? = nil,
        controlName: String? = nil,
        controlValue: String? = nil,
        clickX: Double? = nil,
        clickY: Double? = nil,
        windowClickX: Double? = nil,
        windowClickY: Double? = nil,
        nearbyText: String? = nil,
        url: String? = nil,
        screenshotPath: String? = nil,
        audioPath: String? = nil,
        transcriptPath: String? = nil,
        windowIdentifier: String? = nil,
        triggerMetadata: String? = nil,
        aiPrompt: String? = nil,
        aiResponse: String? = nil,
        aiAttachedWindow: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.eventType = eventType
        self.controlRole = controlRole
        self.controlName = controlName
        self.controlValue = controlValue
        self.clickX = clickX
        self.clickY = clickY
        self.windowClickX = windowClickX
        self.windowClickY = windowClickY
        self.nearbyText = nearbyText
        self.url = url
        self.screenshotPath = screenshotPath
        self.audioPath = audioPath
        self.transcriptPath = transcriptPath
        self.windowIdentifier = windowIdentifier
        self.triggerMetadata = triggerMetadata
        self.aiPrompt = aiPrompt
        self.aiResponse = aiResponse
        self.aiAttachedWindow = aiAttachedWindow
    }
}

// MARK: - JSON coding with ISO 8601 millisecond precision

extension ActivityEvent {
    /// A shared encoder configured for stable, human-readable JSONL output.
    static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601MillisecondPrecision
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    /// A shared decoder that matches the encoder's date strategy.
    static let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601MillisecondPrecision
        return dec
    }()

    /// Returns the JSONL representation of this event (one line of JSON, no trailing newline).
    func jsonlLine() throws -> String {
        let data = try ActivityEvent.jsonEncoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - JSONEncoder.DateEncodingStrategy helpers

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601MillisecondPrecision: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(ActivityEvent.iso8601Formatter.string(from: date))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601MillisecondPrecision: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let date = ActivityEvent.iso8601Formatter.date(from: str) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(str)"
            )
        }
        return date
    }
}

extension ActivityEvent {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
