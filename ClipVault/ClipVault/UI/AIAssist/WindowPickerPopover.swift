import AppKit

/// Lightweight grid picker for selecting a window to attach to an AI Assist
/// request. Built as an `NSPopover` anchored to the 📎 button on the voice
/// recording panel.
///
/// The popover enumerates `CapturableWindow`s once on show, renders a 3-column
/// grid of live thumbnails, and invokes `onSelect` with the user's pick (or
/// `nil` if they tap "No screenshot"). Closes itself after a selection.
final class WindowPickerPopover {

    let popover: NSPopover
    private let viewController = NSViewController()
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detachButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Attach a window screenshot")
    private let dataSource = WindowPickerDataSource()

    /// Called when the user picks a window or chooses "No screenshot" (`nil`).
    var onSelect: ((CapturableWindow?) -> Void)?

    /// Currently-selected window — used to render a checkmark badge on the
    /// matching tile so the user can see what's already attached.
    var currentSelection: CapturableWindow?

    init() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        configure()
    }

    // MARK: - Public API

    func show(from view: NSView) {
        refreshContents()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.performClose(nil)
    }

    // MARK: - Configuration

    private func configure() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        container.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        container.addSubview(titleLabel)

        detachButton.translatesAutoresizingMaskIntoConstraints = false
        detachButton.bezelStyle = .inline
        detachButton.isBordered = false
        detachButton.font = .systemFont(ofSize: 10, weight: .medium)
        detachButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        detachButton.title = "No screenshot"
        detachButton.target = self
        detachButton.action = #selector(detachTapped)
        container.addSubview(detachButton)

        let layout = NSCollectionViewGridLayout()
        layout.maximumNumberOfColumns = 3
        layout.minimumItemSize = NSSize(width: 132, height: 110)
        layout.maximumItemSize = NSSize(width: 144, height: 120)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = dataSource
        collectionView.delegate = dataSource
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            WindowPickerCell.self,
            forItemWithIdentifier: WindowPickerCell.reuseID
        )
        dataSource.onSelect = { [weak self] window in
            self?.onSelect?(window)
            self?.close()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 460),
            container.heightAnchor.constraint(equalToConstant: 360),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            detachButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            detachButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        viewController.view = container
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 460, height: 360)
    }

    @objc private func detachTapped() {
        onSelect?(nil)
        close()
    }

    private func refreshContents() {
        if !WindowScreenshotService.isScreenRecordingGranted {
            statusLabel.stringValue = "Enable Screen Recording for BrainCache in System Settings to attach window screenshots."
            statusLabel.isHidden = false
            scrollView.isHidden = true
            dataSource.windows = []
            collectionView.reloadData()
            return
        }
        statusLabel.stringValue = "Loading windows…"
        statusLabel.isHidden = false
        scrollView.isHidden = true
        dataSource.windows = []
        collectionView.reloadData()
        dataSource.selectedWindowID = currentSelection?.id

        let service = WindowScreenshotService()
        Task { [weak self] in
            let windows = await service.enumerateCapturableWindows()
            await MainActor.run {
                guard let self else { return }
                self.dataSource.windows = windows
                self.collectionView.reloadData()
                if windows.isEmpty {
                    self.statusLabel.stringValue = "No capturable windows found."
                    self.statusLabel.isHidden = false
                    self.scrollView.isHidden = true
                } else {
                    self.statusLabel.isHidden = true
                    self.scrollView.isHidden = false
                }
            }
            // Lazy-load thumbnails after the grid is visible so the popover
            // appears instantly with placeholder tiles.
            for window in windows {
                if let thumb = await service.thumbnail(for: window) {
                    await MainActor.run { [weak self] in
                        self?.dataSource.thumbnails[window.id] = thumb
                        if let idx = self?.dataSource.windows.firstIndex(of: window) {
                            let path = IndexPath(item: idx, section: 0)
                            self?.collectionView.reloadItems(at: [path])
                        }
                    }
                }
            }
        }
    }
}

// MARK: - DataSource + Delegate

private final class WindowPickerDataSource: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var windows: [CapturableWindow] = []
    var thumbnails: [CGWindowID: NSImage] = [:]
    var selectedWindowID: CGWindowID?
    var onSelect: ((CapturableWindow) -> Void)?

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        windows.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: WindowPickerCell.reuseID,
            for: indexPath
        ) as! WindowPickerCell
        let window = windows[indexPath.item]
        item.configure(
            with: window,
            thumbnail: thumbnails[window.id],
            isSelected: window.id == selectedWindowID
        )
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let path = indexPaths.first, path.item < windows.count else { return }
        onSelect?(windows[path.item])
    }
}

// MARK: - Cell

final class WindowPickerCell: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("WindowPickerCell")

    private let thumbnailView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let appField = NSTextField(labelWithString: "")
    private let appIconView = NSImageView()
    private let checkmark = NSImageView()
    private let placeholderLayer = CAShapeLayer()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 110))
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        root.layer?.borderWidth = 1

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        root.addSubview(thumbnailView)

        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyDown
        root.addSubview(appIconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 10, weight: .medium)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        root.addSubview(titleField)

        appField.translatesAutoresizingMaskIntoConstraints = false
        appField.font = .systemFont(ofSize: 9)
        appField.textColor = NSColor.white.withAlphaComponent(0.6)
        appField.lineBreakMode = .byTruncatingTail
        appField.maximumNumberOfLines = 1
        root.addSubview(appField)

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")
        checkmark.contentTintColor = NSColor.systemBlue
        checkmark.imageScaling = .scaleProportionallyDown
        checkmark.isHidden = true
        root.addSubview(checkmark)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnailView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            thumbnailView.heightAnchor.constraint(equalToConstant: 70),

            appIconView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            appIconView.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            appIconView.widthAnchor.constraint(equalToConstant: 14),
            appIconView.heightAnchor.constraint(equalToConstant: 14),

            titleField.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 4),
            titleField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),

            appField.leadingAnchor.constraint(equalTo: appIconView.leadingAnchor),
            appField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            appField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),

            checkmark.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 4),
            checkmark.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -4),
            checkmark.widthAnchor.constraint(equalToConstant: 16),
            checkmark.heightAnchor.constraint(equalToConstant: 16),
        ])

        view = root
    }

    func configure(with window: CapturableWindow, thumbnail: NSImage?, isSelected: Bool) {
        thumbnailView.image = thumbnail
        appIconView.image = window.appIcon
        titleField.stringValue = window.title.isEmpty ? window.appName : window.title
        appField.stringValue = window.title.isEmpty ? "" : window.appName
        checkmark.isHidden = !isSelected
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderColor = (isSelected
                ? NSColor.systemBlue
                : NSColor.white.withAlphaComponent(0.10)).cgColor
            view.layer?.borderWidth = isSelected ? 2 : 1
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        appIconView.image = nil
        titleField.stringValue = ""
        appField.stringValue = ""
        checkmark.isHidden = true
    }
}
