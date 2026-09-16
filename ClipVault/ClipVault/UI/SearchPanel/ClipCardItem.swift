import AppKit

// MARK: - HTML helpers

extension String {
    /// Fast tag-strip for card/row previews (no WebKit, safe off main thread).
    var strippingHTMLTags: String {
        let stripped = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders HTML into an `NSAttributedString`. Must be called on the main thread.
    func attributedStringFromHTML(defaultFont: NSFont) -> NSAttributedString? {
        guard let data = data(using: .utf8) else { return nil }
        guard let attr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attr)
        mutable.enumerateAttribute(.font, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            guard let existingFont = value as? NSFont else { return }
            let descriptor = existingFont.fontDescriptor
            let traits = descriptor.symbolicTraits
            var newFont = defaultFont
            if traits.contains(.bold) && traits.contains(.italic) {
                newFont = NSFontManager.shared.convert(defaultFont, toHaveTrait: [.boldFontMask, .italicFontMask])
            } else if traits.contains(.bold) {
                newFont = NSFontManager.shared.convert(defaultFont, toHaveTrait: .boldFontMask)
            } else if traits.contains(.italic) {
                newFont = NSFontManager.shared.convert(defaultFont, toHaveTrait: .italicFontMask)
            }
            mutable.addAttribute(.font, value: newFont, range: range)
        }
        return mutable
    }
}

final class ClipCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ClipCardItem")
    static let cardWidth: CGFloat = 180

    override func loadView() {
        view = ClipCardView()
    }

    override var isSelected: Bool {
        didSet { (view as? ClipCardView)?.updateSelection(isSelected) }
    }

    func configure(with record: ClipRecord, isSemanticOnly: Bool = false) {
        (view as? ClipCardView)?.configure(with: record, isSemanticOnly: isSemanticOnly)
    }

    func configureAsAIAnswer(text: String, isStreaming: Bool, isInterimTrace: Bool = false) {
        (view as? ClipCardView)?.configureAsAIAnswer(
            text: text,
            isStreaming: isStreaming,
            isInterimTrace: isInterimTrace
        )
    }
}

// MARK: - Caches

private enum CardCaches {
    static let appIcons: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 50
        return c
    }()

    static let thumbnails: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 100
        c.totalCostLimit = 30 * 1024 * 1024 // 30 MB
        return c
    }()

    static let attributedPreviews: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 200
        return c
    }()

    static func attributedPreview(for key: String) -> NSAttributedString? {
        attributedPreviews.object(forKey: key as NSString)
    }

    static func storeAttributedPreview(_ s: NSAttributedString, for key: String) {
        attributedPreviews.setObject(s, forKey: key as NSString)
    }

    static func appIcon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = appIcons.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons.setObject(icon, forKey: key)
        return icon
    }

    static func thumbnail(for filename: String) -> NSImage? {
        thumbnails.object(forKey: filename as NSString)
    }

    static func storeThumbnail(_ image: NSImage, for filename: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        thumbnails.setObject(image, forKey: filename as NSString, cost: cost)
    }
}

private enum ClipCardPalette {
    static let background = NSColor(white: 0.14, alpha: 0.92)
    static let backgroundSelected = NSColor(white: 0.19, alpha: 0.96)
    static let border = NSColor(white: 1.0, alpha: 0.10)
    static let secondaryText = NSColor(white: 1.0, alpha: 0.76)
    static let tertiaryText = NSColor(white: 1.0, alpha: 0.60)
}

// MARK: - Card view

final class ClipCardView: NSView {

    private let typeBadge = NSTextField(labelWithString: "")
    private let semanticBadge = NSImageView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private let appIconView = NSImageView()
    private let contentLabel: NSTextField = {
        let f = NSTextField(wrappingLabelWithString: "")
        f.maximumNumberOfLines = 6
        f.lineBreakMode = .byTruncatingTail
        f.cell?.truncatesLastVisibleLine = true
        return f
    }()
    private let aiAnswerTextView: NSTextView = {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.font = .systemFont(ofSize: 12)
        tv.textColor = .labelColor
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineBreakMode = .byWordWrapping
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return tv
    }()
    private let aiAnswerScrollView: NSScrollView = {
        let sv = NSScrollView(frame: .zero)
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = false
        sv.isHidden = true
        return sv
    }()
    private let imagePreview = NSImageView()
    private let tagsLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let pinIcon = NSImageView()
    private let descriptionButton: NSButton = {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "text.below.photo",
                            accessibilityDescription: "AI description")
        btn.contentTintColor = .white
        btn.imageScaling = .scaleProportionallyDown
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 4
        btn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        btn.isHidden = true
        btn.toolTip = "View AI description"
        return btn
    }()

    private var currentRecordID: Int64?
    private var isAudioTranscriptCard = false
    private var storedImageDescription: String?
    private var descriptionButtonTarget: AnyObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = ClipCardPalette.background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ClipCardPalette.border.cgColor
        aiAnswerScrollView.documentView = aiAnswerTextView

        let allViews: [NSView] = [typeBadge, semanticBadge, timestampLabel, appIconView,
                                   contentLabel, aiAnswerScrollView, imagePreview, descriptionButton, tagsLabel,
                                   footerLabel, pinIcon]
        for v in allViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        typeBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        typeBadge.setContentHuggingPriority(.required, for: .horizontal)

        // Semantic indicator — sparkles icon shown for vector-only results
        semanticBadge.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Semantic match")
        semanticBadge.contentTintColor = .systemPurple
        semanticBadge.imageScaling = .scaleProportionallyDown
        semanticBadge.isHidden = true
        semanticBadge.toolTip = "Found via semantic (vector) search"

        timestampLabel.font = .systemFont(ofSize: 10)
        timestampLabel.textColor = ClipCardPalette.secondaryText
        timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        appIconView.imageScaling = .scaleProportionallyDown

        contentLabel.font = .systemFont(ofSize: 12)
        contentLabel.textColor = .labelColor
        contentLabel.isSelectable = false

        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.wantsLayer = true
        imagePreview.layer?.cornerRadius = 6
        imagePreview.layer?.masksToBounds = true
        imagePreview.isHidden = true

        tagsLabel.font = .systemFont(ofSize: 9)
        tagsLabel.textColor = .systemPurple
        tagsLabel.lineBreakMode = .byTruncatingTail
        tagsLabel.isHidden = true

        footerLabel.font = .systemFont(ofSize: 9)
        footerLabel.textColor = ClipCardPalette.tertiaryText

        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "pinned")
        pinIcon.contentTintColor = ClipCardPalette.secondaryText
        pinIcon.isHidden = true

        let pad: CGFloat = 12
        let iconSize: CGFloat = 18
        let semanticSize: CGFloat = 12

        NSLayoutConstraint.activate([
            typeBadge.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            typeBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),

            semanticBadge.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor),
            semanticBadge.leadingAnchor.constraint(equalTo: typeBadge.trailingAnchor, constant: 4),
            semanticBadge.widthAnchor.constraint(equalToConstant: semanticSize),
            semanticBadge.heightAnchor.constraint(equalToConstant: semanticSize),

            appIconView.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor),
            appIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            appIconView.widthAnchor.constraint(equalToConstant: iconSize),
            appIconView.heightAnchor.constraint(equalToConstant: iconSize),

            timestampLabel.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor),
            timestampLabel.trailingAnchor.constraint(equalTo: appIconView.leadingAnchor, constant: -4),

            contentLabel.topAnchor.constraint(equalTo: typeBadge.bottomAnchor, constant: 8),
            contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            contentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            contentLabel.bottomAnchor.constraint(lessThanOrEqualTo: tagsLabel.topAnchor, constant: -4),

            aiAnswerScrollView.topAnchor.constraint(equalTo: typeBadge.bottomAnchor, constant: 8),
            aiAnswerScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            aiAnswerScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            aiAnswerScrollView.bottomAnchor.constraint(equalTo: tagsLabel.topAnchor, constant: -4),

            imagePreview.topAnchor.constraint(equalTo: typeBadge.bottomAnchor, constant: 8),
            imagePreview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            imagePreview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            imagePreview.bottomAnchor.constraint(lessThanOrEqualTo: tagsLabel.topAnchor, constant: -4),

            descriptionButton.trailingAnchor.constraint(equalTo: imagePreview.trailingAnchor, constant: -4),
            descriptionButton.bottomAnchor.constraint(equalTo: imagePreview.bottomAnchor, constant: -4),
            descriptionButton.widthAnchor.constraint(equalToConstant: 22),
            descriptionButton.heightAnchor.constraint(equalToConstant: 22),

            tagsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            tagsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            tagsLabel.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -2),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            pinIcon.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
            pinIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func layout() {
        super.layout()
        layoutAIAnswerTextViewIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if isAudioTranscriptCard {
            return self
        }
        return hitView
    }

    // MARK: - Configuration

    func configure(with record: ClipRecord, isSemanticOnly: Bool = false) {
        currentRecordID = record.id
        isAudioTranscriptCard = record.isAudioTranscript
        contentLabel.maximumNumberOfLines = 6
        contentLabel.lineBreakMode = .byTruncatingTail
        aiAnswerScrollView.isHidden = true
        aiAnswerScrollView.hasVerticalScroller = false
        aiAnswerTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))

        let (name, color) = record.isAudioTranscript
            ? ("Transcript", NSColor.systemTeal)
            : Self.typeDisplayInfo(for: record.contentType)
        typeBadge.stringValue = name
        typeBadge.textColor = color

        let date = Date(timeIntervalSince1970: record.createdAt)
        timestampLabel.stringValue = ClipRowView.formatDate(date)

        if record.isAudioTranscript {
            appIconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Audio transcript")
            appIconView.contentTintColor = .systemTeal
        } else {
            appIconView.image = record.sourceApp.flatMap { CardCaches.appIcon(for: $0) }
            appIconView.contentTintColor = nil
        }

        let isImage = record.contentType == ClipboardContentType.image.rawValue
        contentLabel.isHidden = isImage
        aiAnswerScrollView.isHidden = true
        imagePreview.isHidden = !isImage

        storedImageDescription = nil
        descriptionButton.isHidden = true

        if isImage, let filename = record.mediaFileName {
            if let cached = CardCaches.thumbnail(for: filename) {
                imagePreview.image = cached
            } else {
                imagePreview.image = nil
                let rid = record.id
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let data = try? MediaFileManager.shared.load(filename: filename),
                          let image = NSImage(data: data) else { return }
                    let thumb = Self.downsample(image, maxSide: 180)
                    CardCaches.storeThumbnail(thumb, for: filename)
                    DispatchQueue.main.async {
                        guard let self, self.currentRecordID == rid else { return }
                        self.imagePreview.image = thumb
                    }
                }
            }

            if let desc = record.imageDescription, !desc.isEmpty {
                storedImageDescription = desc
                descriptionButton.isHidden = false
                let target = ActionTarget { [weak self] in
                    self?.showDescriptionPopover()
                }
                descriptionButtonTarget = target
                descriptionButton.target = target
                descriptionButton.action = #selector(ActionTarget.run)
            }
        } else if let text = record.textContent, !text.isEmpty {
            let isHTML = record.contentType == ClipboardContentType.html.rawValue
            let isRTF = record.contentType == ClipboardContentType.rtf.rawValue
            if (isHTML || isRTF), let id = record.id, let filename = record.mediaFileName {
                let cacheKey = "\(id)-\(record.contentType)"
                if let cached = CardCaches.attributedPreview(for: cacheKey) {
                    contentLabel.attributedStringValue = cached
                } else {
                    // Show plain fallback immediately, then upgrade to formatted preview.
                    contentLabel.stringValue = Self.previewText(from: text, isHTML: isHTML)
                    let rid = id
                    let isHTMLClip = isHTML
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let data = try? MediaFileManager.shared.load(filename: filename) else { return }
                        if isHTMLClip {
                            // HTML document loader must run on the main thread.
                            DispatchQueue.main.async {
                                guard let self else { return }
                                guard let preview = Self.renderHTMLPreview(data: data) else { return }
                                CardCaches.storeAttributedPreview(preview, for: cacheKey)
                                guard self.currentRecordID == rid else { return }
                                self.contentLabel.attributedStringValue = preview
                            }
                        } else {
                            guard let preview = Self.renderRTFPreview(data: data) else { return }
                            CardCaches.storeAttributedPreview(preview, for: cacheKey)
                            DispatchQueue.main.async {
                                guard let self, self.currentRecordID == rid else { return }
                                self.contentLabel.attributedStringValue = preview
                            }
                        }
                    }
                }
            } else {
                contentLabel.stringValue = Self.previewText(from: text, isHTML: isHTML)
            }
        } else if !record.isIndexed {
            contentLabel.stringValue = "[Content not searchable]"
        } else {
            contentLabel.stringValue = "[Binary content]"
        }

        if isImage, let desc = record.imageDescription, !desc.isEmpty {
            footerLabel.stringValue = "AI: " + desc.prefix(40).replacingOccurrences(of: "\n", with: " ")
            toolTip = desc
        } else if record.isAudioTranscript {
            footerLabel.stringValue = "Enter opens preview - \(Self.formatCharCount(record.byteSize))"
            toolTip = "Enter opens transcript preview"
        } else if let text = record.textContent {
            footerLabel.stringValue = Self.formatCharCount(text.count)
            toolTip = nil
        } else {
            footerLabel.stringValue = Self.formatByteSize(record.byteSize)
            toolTip = nil
        }

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

        pinIcon.isHidden = !record.isPinned
    }

    func configureAsAIAnswer(text: String, isStreaming: Bool, isInterimTrace: Bool = false) {
        currentRecordID = nil
        isAudioTranscriptCard = false
        storedImageDescription = nil
        descriptionButton.isHidden = true
        descriptionButton.target = nil
        descriptionButton.action = nil
        descriptionButtonTarget = nil

        typeBadge.stringValue = "AI Response"
        typeBadge.textColor = .systemTeal
        semanticBadge.isHidden = true
        timestampLabel.stringValue = "Ask mode"
        appIconView.image = nil

        contentLabel.isHidden = true
        aiAnswerScrollView.isHidden = false
        aiAnswerScrollView.hasVerticalScroller = isStreaming
        if isInterimTrace {
            aiAnswerTextView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
            )
        } else {
            aiAnswerTextView.textStorage?.setAttributedString(
                MarkdownRenderer.render(text, fontSize: 12, textColor: .labelColor)
            )
        }
        layoutAIAnswerTextViewIfNeeded()
        if !text.isEmpty {
            let range = NSRange(location: text.utf16.count - 1, length: 1)
            aiAnswerTextView.scrollRangeToVisible(range)
        }
        imagePreview.isHidden = true
        imagePreview.image = nil

        tagsLabel.stringValue = ""
        tagsLabel.isHidden = true
        if isInterimTrace {
            footerLabel.stringValue = "Thinking and calling tools…"
        } else {
            footerLabel.stringValue = isStreaming
                ? "Streaming answer…"
                : "Press Enter to paste answer"
        }
        pinIcon.isHidden = true
        toolTip = text
    }

    private func layoutAIAnswerTextViewIfNeeded() {
        guard !aiAnswerScrollView.isHidden else { return }
        let contentSize = aiAnswerScrollView.contentSize
        guard contentSize.width > 0 else { return }

        aiAnswerTextView.minSize = NSSize(width: contentSize.width, height: contentSize.height)
        aiAnswerTextView.maxSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        aiAnswerTextView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        aiAnswerTextView.frame = NSRect(origin: .zero, size: contentSize)

        guard let textContainer = aiAnswerTextView.textContainer,
              let layoutManager = aiAnswerTextView.layoutManager else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height + aiAnswerTextView.textContainerInset.height * 2)
        let targetHeight = max(contentSize.height, usedHeight)
        aiAnswerTextView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: targetHeight
        )
    }

    func updateSelection(_ selected: Bool) {
        if selected {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = ClipCardPalette.backgroundSelected.cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = ClipCardPalette.border.cgColor
            layer?.backgroundColor = ClipCardPalette.background.cgColor
        }
    }

    // MARK: - Description popover

    private func showDescriptionPopover() {
        guard let description = storedImageDescription else { return }

        let popoverWidth: CGFloat = 300
        let popover = NSPopover()
        popover.behavior = .transient

        let vc = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "AI Description")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        container.addSubview(titleLabel)

        let descView = NSTextField(wrappingLabelWithString: description)
        descView.translatesAutoresizingMaskIntoConstraints = false
        descView.font = .systemFont(ofSize: 13)
        descView.textColor = .labelColor
        descView.isSelectable = true
        container.addSubview(descView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            descView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            descView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            descView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            descView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            descView.widthAnchor.constraint(lessThanOrEqualToConstant: popoverWidth - 24),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.show(relativeTo: descriptionButton.bounds, of: descriptionButton, preferredEdge: .maxY)
    }

    // MARK: - Tags decoding

    /// Decodes a JSON-encoded string array stored in `ClipRecord.tags`.
    static func decodeTags(from json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return tags
    }

    // MARK: - Helpers

    private static func typeDisplayInfo(for contentType: String) -> (String, NSColor) {
        switch contentType {
        case ClipboardContentType.text.rawValue:  return ("Text",  .systemGreen)
        case ClipboardContentType.image.rawValue: return ("Image", .systemBlue)
        case ClipboardContentType.html.rawValue:  return ("HTML",  .systemPurple)
        case ClipboardContentType.rtf.rawValue:   return ("RTF",   .systemOrange)
        case ClipboardContentType.pdf.rawValue:   return ("PDF",   .systemRed)
        case ClipboardContentType.file.rawValue:  return ("File",  .systemPink)
        default:                                   return ("Text",  .systemGreen)
        }
    }

    private static let charCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let previewCharacterLimit = 600

    private static func formatCharCount(_ count: Int) -> String {
        let str = charCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(str) characters"
    }

    private static func previewText(from text: String, isHTML: Bool) -> String {
        let normalized = isHTML ? text.strippingHTMLTags : text
        guard normalized.count > previewCharacterLimit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: previewCharacterLimit)
        return String(normalized[..<end]) + "..."
    }

    // MARK: - Rich preview rendering

    /// Cap the raw payload we hand to the HTML/RTF decoder. The card preview
    /// only shows ~6 lines, and parsing megabytes of Word HTML can stall the
    /// main thread.
    private static let richPreviewMaxBytes = 8 * 1024

    private static func renderHTMLPreview(data: Data) -> NSAttributedString? {
        let truncated = data.count > richPreviewMaxBytes
            ? data.prefix(richPreviewMaxBytes)
            : data
        guard let attr = try? NSAttributedString(
            data: Data(truncated),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else { return nil }
        return reformatRichPreview(attr)
    }

    private static func renderRTFPreview(data: Data) -> NSAttributedString? {
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return reformatRichPreview(attr)
    }

    /// Normalises a rich attributed string for in-card preview: maps fonts to
    /// the card's body size while preserving bold/italic traits, forces the
    /// foreground color to `.labelColor` so dark-theme text stays readable,
    /// strips background colors / shadows the source page baked in (otherwise
    /// HTML copied from a white web page paints solid white blocks on the
    /// dark card), and truncates to `previewCharacterLimit` glyphs.
    private static func reformatRichPreview(_ attr: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let baseFont = NSFont.systemFont(ofSize: 12)
        mutable.enumerateAttribute(.font, in: fullRange) { value, r, _ in
            let traits: NSFontDescriptor.SymbolicTraits
            if let existing = value as? NSFont {
                traits = existing.fontDescriptor.symbolicTraits
            } else {
                traits = []
            }
            let newFont: NSFont
            if traits.contains(.bold) && traits.contains(.italic) {
                newFont = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
            } else if traits.contains(.bold) {
                newFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            } else if traits.contains(.italic) {
                newFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            } else {
                newFont = baseFont
            }
            mutable.addAttribute(.font, value: newFont, range: r)
        }
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        // Drop attributes the source document baked in that would clash with
        // the dark card chrome — most notably opaque white backgrounds.
        mutable.removeAttribute(.backgroundColor, range: fullRange)
        mutable.removeAttribute(.shadow, range: fullRange)
        mutable.removeAttribute(.strokeColor, range: fullRange)
        mutable.removeAttribute(.underlineColor, range: fullRange)
        if mutable.length > previewCharacterLimit {
            let truncatedRange = NSRange(location: 0, length: previewCharacterLimit)
            let trimmed = NSMutableAttributedString(attributedString: mutable.attributedSubstring(from: truncatedRange))
            trimmed.append(NSAttributedString(
                string: "…",
                attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]
            ))
            return trimmed
        }
        return mutable
    }

    private static func downsample(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxSide || size.height > maxSide else { return image }
        let scale = maxSide / max(size.width, size.height)
        let newSize = NSSize(width: round(size.width * scale), height: round(size.height * scale))
        let thumb = NSImage(size: newSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    private static func formatByteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
