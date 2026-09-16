import AppKit

/// A modal sheet for editing the activity capture screenshot exclusion list.
///
/// Shows bundle IDs one per line in a scrollable `NSTextView`. The user can
/// add, remove, or edit entries. Saving commits the changes; cancelling discards
/// them. Empty lines and whitespace-only lines are silently removed on save.
///
/// Usage:
/// ```swift
/// ExclusionListSheet.run(relativeTo: window) { updatedList in
///     guard let list = updatedList else { return }  // nil = user cancelled
///     Settings.shared.activityCaptureExcludedBundleIDs = list
/// }
/// ```
enum ExclusionListSheet {

    /// Presents the sheet as a window-modal panel attached to `window` (or as
    /// an app-modal panel if `window` is nil). Calls `completion` on the main
    /// queue when the user dismisses the sheet. Returns the new list on Save,
    /// or `nil` if the user cancelled.
    static func run(relativeTo window: NSWindow?, completion: @escaping ([String]?) -> Void) {
        let panel = ExclusionListPanel(completion: completion)
        if let window = window {
            // Capture `panel` in the sheet completion closure so the window controller
            // stays alive until the sheet is dismissed. Without this, `panel` goes out
            // of scope as soon as `run` returns and the button targets become dangling.
            window.beginSheet(panel.window!) { [panel] _ in _ = panel }
        } else {
            NSApp.runModal(for: panel.window!)
        }
    }
}

// MARK: - Internal panel controller

private final class ExclusionListPanel: NSWindowController {

    private let textView = NSTextView()
    private let completion: ([String]?) -> Void

    init(completion: @escaping ([String]?) -> Void) {
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Excluded Apps"
        panel.minSize = NSSize(width: 320, height: 200)

        super.init(window: panel)
        buildUI(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func buildUI(in panel: NSPanel) {
        let contentView = NSView()
        panel.contentView = contentView

        // Description label
        let descLabel = NSTextField(wrappingLabelWithString:
            "Enter one Bundle ID per line. Interactions and screenshots from these apps will not be recorded.\n\nExample: com.apple.Safari")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scroll + text view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scrollView.documentView = textView

        // Seed with current exclusion list (one per line).
        textView.string = Settings.shared.activityCaptureExcludedBundleIDs.joined(separator: "\n")

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1B}"  // Escape
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        [descLabel, scrollView, cancelButton, saveButton].forEach { contentView.addSubview($0) }

        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: m),
            descLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            descLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            scrollView.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            saveButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -m),

            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])
    }

    @objc private func save() {
        let lines = textView.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        dismiss(result: lines)
    }

    @objc private func cancel() {
        dismiss(result: nil)
    }

    private func dismiss(result: [String]?) {
        guard let w = window else { return }
        if let sheetParent = w.sheetParent {
            sheetParent.endSheet(w)
        } else {
            NSApp.stopModal()
            w.orderOut(nil)
        }
        completion(result)
    }
}
