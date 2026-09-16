import AppKit

/// Table cell view displaying a single clipboard entry.
final class ClipRowView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("ClipRowView")
    /// Base row height with no tags. Use `rowHeight(for:)` when tags may be present.
    static let rowHeight: CGFloat = 52
    /// Row height when tag badges are shown below the preview.
    static let rowHeightWithTags: CGFloat = 68

    private let typeIconView = NSImageView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceAppIconView = NSImageView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private let tagsLabel = NSTextField(labelWithString: "")
    private let semanticBadge = NSImageView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    private func setupSubviews() {
        // Type icon (SF Symbol)
        typeIconView.translatesAutoresizingMaskIntoConstraints = false
        typeIconView.imageScaling = .scaleProportionallyDown
        addSubview(typeIconView)

        // Preview label
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.isEditable = false
        previewLabel.isBordered = false
        previewLabel.drawsBackground = false
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.font = NSFont.systemFont(ofSize: 14)
        addSubview(previewLabel)

        // Source app icon
        sourceAppIconView.translatesAutoresizingMaskIntoConstraints = false
        sourceAppIconView.imageScaling = .scaleProportionallyDown
        addSubview(sourceAppIconView)

        // Timestamp label
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.isEditable = false
        timestampLabel.isBordered = false
        timestampLabel.drawsBackground = false
        timestampLabel.font = NSFont.systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabelColor
        addSubview(timestampLabel)

        // Tags label — hidden by default, shown when tags are present
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false
        tagsLabel.isEditable = false
        tagsLabel.isBordered = false
        tagsLabel.drawsBackground = false
        tagsLabel.font = NSFont.systemFont(ofSize: 9)
        tagsLabel.textColor = .systemPurple
        tagsLabel.lineBreakMode = .byTruncatingTail
        tagsLabel.isHidden = true
        addSubview(tagsLabel)

        // Semantic indicator — sparkles icon shown for vector-only results
        semanticBadge.translatesAutoresizingMaskIntoConstraints = false
        semanticBadge.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Semantic match")
        semanticBadge.contentTintColor = .systemPurple
        semanticBadge.imageScaling = .scaleProportionallyDown
        semanticBadge.isHidden = true
        semanticBadge.toolTip = "Found via semantic (vector) search"
        addSubview(semanticBadge)

        let margin: CGFloat = 8
        let iconSize: CGFloat = 20
        let appIconSize: CGFloat = 16
        let semanticSize: CGFloat = 12

        NSLayoutConstraint.activate([
            // Type icon
            typeIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            typeIconView.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            typeIconView.widthAnchor.constraint(equalToConstant: iconSize),
            typeIconView.heightAnchor.constraint(equalToConstant: iconSize),

            // Source app icon
            sourceAppIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            sourceAppIconView.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            sourceAppIconView.widthAnchor.constraint(equalToConstant: appIconSize),
            sourceAppIconView.heightAnchor.constraint(equalToConstant: appIconSize),

            // Timestamp label
            timestampLabel.trailingAnchor.constraint(equalTo: sourceAppIconView.leadingAnchor, constant: -6),
            timestampLabel.centerYAnchor.constraint(equalTo: sourceAppIconView.centerYAnchor),
            timestampLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            // Semantic badge (next to timestamp)
            semanticBadge.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -4),
            semanticBadge.centerYAnchor.constraint(equalTo: timestampLabel.centerYAnchor),
            semanticBadge.widthAnchor.constraint(equalToConstant: semanticSize),
            semanticBadge.heightAnchor.constraint(equalToConstant: semanticSize),

            // Preview label
            previewLabel.leadingAnchor.constraint(equalTo: typeIconView.trailingAnchor, constant: 8),
            previewLabel.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -8),
            previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            previewLabel.heightAnchor.constraint(equalToConstant: 20),

            // Tags label below preview
            tagsLabel.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            tagsLabel.trailingAnchor.constraint(equalTo: previewLabel.trailingAnchor),
            tagsLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 2),
        ])
    }

    // Tracks the record ID to cancel stale async thumbnail loads
    private var currentRecordID: Int64?

    // MARK: - Configuration

    func configure(with record: ClipRecord, isSemanticOnly: Bool = false) {
        currentRecordID = record.id

        // Type icon — images get a lazy-loaded thumbnail; other types use SF Symbols
        if record.isAudioTranscript {
            typeIconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Audio transcript")
            typeIconView.contentTintColor = .systemTeal
        } else if record.contentType == ClipboardContentType.image.rawValue,
           let filename = record.mediaFileName {
            typeIconView.contentTintColor = nil
            typeIconView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "image")
            let rid = record.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = try? MediaFileManager.shared.load(filename: filename),
                      let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self, self.currentRecordID == rid else { return }
                    self.typeIconView.image = image
                }
            }
        } else {
            typeIconView.contentTintColor = nil
            let symbolName = Self.symbolName(for: record.contentType)
            typeIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: record.contentType)
        }

        // Preview text
        if !record.isIndexed {
            previewLabel.stringValue = "[Content not searchable]"
        } else if let text = record.textContent, !text.isEmpty {
            let isHTML = record.contentType == ClipboardContentType.html.rawValue
            previewLabel.stringValue = isHTML ? text.strippingHTMLTags : text
        } else {
            previewLabel.stringValue = "[Binary content]"
        }

        // Source app icon — loaded synchronously (small, cheap)
        if let bundleID = record.sourceApp,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            sourceAppIconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            sourceAppIconView.image = nil
        }

        // Timestamp
        let date = Date(timeIntervalSince1970: record.createdAt)
        timestampLabel.stringValue = Self.formatDate(date)

        // Tags — decoded from JSON string array; show first 3 tags
        if let tagsJSON = record.tags,
           let tagList = ClipCardView.decodeTags(from: tagsJSON),
           !tagList.isEmpty {
            tagsLabel.stringValue = tagList.prefix(3).map { "#\($0)" }.joined(separator: " ")
            tagsLabel.isHidden = false
        } else {
            tagsLabel.stringValue = ""
            tagsLabel.isHidden = true
        }

        // Semantic indicator
        semanticBadge.isHidden = !isSemanticOnly
    }

    // MARK: - Row height helper

    /// Returns the appropriate row height based on whether the record has tags.
    static func rowHeight(for record: ClipRecord) -> CGFloat {
        guard let tagsJSON = record.tags,
              let tagList = ClipCardView.decodeTags(from: tagsJSON),
              !tagList.isEmpty else {
            return rowHeight
        }
        return rowHeightWithTags
    }

    // MARK: - Helpers

    private static func symbolName(for contentType: String) -> String {
        switch contentType {
        case ClipboardContentType.image.rawValue: return "photo"
        case ClipboardContentType.rtf.rawValue:   return "doc.richtext"
        case ClipboardContentType.html.rawValue:  return "chevron.left.forwardslash.chevron.right"
        case ClipboardContentType.pdf.rawValue:   return "doc.richtext"
        case ClipboardContentType.file.rawValue:  return "doc"
        default:                                   return "doc.text"
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func formatDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
