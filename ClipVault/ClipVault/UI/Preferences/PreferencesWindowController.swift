import AppKit

final class PreferencesWindowController: NSWindowController {

    enum Tab: Int, CaseIterable {
        case general
        case clipboard
        case activity
        case hotkey
        case ai
        case writing
        case importExport
        case permissions

        var title: String {
            switch self {
            case .general:      return "General"
            case .clipboard:    return "Clipboard"
            case .activity:     return "Activity Recorder"
            case .hotkey:       return "Hotkey"
            case .ai:           return "AI"
            case .writing:      return "Writing"
            case .importExport: return "Import / Export"
            case .permissions:  return "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .general:      return "gearshape"
            case .clipboard:    return "doc.on.clipboard"
            case .activity:     return "record.circle"
            case .hotkey:       return "keyboard"
            case .ai:           return "sparkles"
            case .writing:      return "text.cursor"
            case .importExport: return "square.and.arrow.up.on.square"
            case .permissions:  return "lock.shield"
            }
        }

        var symbolTint: NSColor {
            switch self {
            case .general:      return .systemGray
            case .clipboard:    return .systemBlue
            case .activity:     return .systemRed
            case .hotkey:       return .systemPurple
            case .ai:           return .systemIndigo
            case .writing:      return .systemPink
            case .importExport: return .systemTeal
            case .permissions:  return .systemOrange
            }
        }
    }

    static let shared = PreferencesWindowController()

    private let generalPrefsView = GeneralPrefsView()
    private let clipboardPrefsView = ClipboardPrefsView()
    private let activityPrefsView = ActivityRecorderPrefsView()
    private let hotkeyPrefsView = HotkeyPrefsView()
    private let aiPrefsView = AIPrefsView()
    private let writingPrefsView = WritingPrefsView()
    private let importExportPrefsView = ImportExportPrefsView()
    private let permissionsPrefsView = PermissionsPrefsView()

    private let sidebarVC = PreferencesSidebarController()
    private let detailVC = PreferencesDetailController()
    private let splitVC = NSSplitViewController()

    /// Injected by AppDelegate so ClipboardPrefsView can call deleteAll.
    var clipStore: ClipStore?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BrainCache Preferences"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 460)

        // Empty toolbar gives us the unified title bar (so the window title
        // sits in the toolbar strip and the sidebar visual effect can extend
        // behind it).
        let toolbar = NSToolbar(identifier: "BrainCachePreferencesToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        super.init(window: window)
        window.delegate = self

        sidebarVC.onSelect = { [weak self] tab in
            self?.select(tab: tab)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh + 1

        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 460
        detailItem.canCollapse = false

        splitVC.splitViewItems = [sidebarItem, detailItem]

        window.contentViewController = splitVC

        select(tab: .general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Selection

    private func select(tab: Tab) {
        sidebarVC.setSelected(tab)
        window?.title = tab.title

        let view: NSView
        switch tab {
        case .general:      view = generalPrefsView
        case .clipboard:    view = clipboardPrefsView
        case .activity:     view = activityPrefsView
        case .hotkey:       view = hotkeyPrefsView
        case .ai:           view = aiPrefsView
        case .writing:      view = writingPrefsView
        case .importExport: view = importExportPrefsView
        case .permissions:  view = permissionsPrefsView
        }

        detailVC.setContent(view)

        if view === permissionsPrefsView {
            permissionsPrefsView.refreshAll()
            permissionsPrefsView.startMonitoring()
        } else {
            permissionsPrefsView.stopMonitoring()
        }
    }

    // MARK: - Show

    func show(selecting tab: Tab? = nil) {
        clipboardPrefsView.clipStore = clipStore
        clipboardPrefsView.refresh()
        importExportPrefsView.clipStore = clipStore

        if let tab {
            select(tab: tab)
        }

        permissionsPrefsView.refreshAll()
        window?.center()
        _ = NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSWindowDelegate

extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        permissionsPrefsView.stopMonitoring()
        _ = NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Detail host

private final class PreferencesDetailController: NSViewController {

    private var current: NSView?

    override func loadView() {
        view = NSView()
    }

    func setContent(_ content: NSView) {
        current?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // Anchor to safeAreaLayoutGuide so content sits below the unified
        // toolbar — splitViewItems for non-sidebar columns don't get this for
        // free.
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: guide.topAnchor),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        current = content
    }
}

// MARK: - Sidebar

private final class PreferencesSidebarController: NSViewController {

    var onSelect: ((PreferencesWindowController.Tab) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = ""
        column.minWidth = 120
        column.width = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowHeight = 30
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.focusRingType = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setSelected(_ tab: PreferencesWindowController.Tab) {
        let row = tab.rawValue
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func rowClicked() {
        let row = tableView.selectedRow
        guard row >= 0,
              let tab = PreferencesWindowController.Tab(rawValue: row) else { return }
        onSelect?(tab)
    }
}

extension PreferencesSidebarController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        PreferencesWindowController.Tab.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tab = PreferencesWindowController.Tab(rawValue: row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebarCell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell
        if cell == nil {
            cell = SidebarCell()
            cell?.identifier = id
        }
        cell?.configure(symbol: tab.symbol, tint: tab.symbolTint, title: tab.title)
        return cell
    }
}

private final class SidebarCell: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        textField = titleLabel

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(symbol: String, tint: NSColor, title: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.contentTintColor = tint
        titleLabel.stringValue = title
    }
}
