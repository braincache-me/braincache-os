import AppKit

/// Protocol that the sidebar uses to notify its owner about day selection and deletion.
protocol ActivityHistorySidebarDelegate: AnyObject {
    func sidebarDidSelectDay(_ dayString: String)
    /// Called when the user confirms deleting a day via the right-click context menu.
    func sidebarDidRequestDeleteDay(_ dayString: String)
}

// MARK: - Context-menu-aware table view

/// NSTableView subclass that overrides `menu(for:)` to provide row-level context menus.
final class SidebarTableView: NSTableView {
    weak var menuProvider: ActivityHistorySidebarView?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?.makeContextMenu(forRow: row)
    }
}

/// Left-panel sidebar for the Activity History window.
///
/// Displays a reverse-chronological list of days with event counts and total storage.
/// Notifies `delegate` when the user selects a day row.
final class ActivityHistorySidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    let tableView = SidebarTableView()
    private let footerLabel = NSTextField(labelWithString: "")

    // MARK: - State

    weak var delegate: ActivityHistorySidebarDelegate?

    private var days: [ActivityDaySummary] = []
    private(set) var selectedDayString: String? = nil
    private var suppressDelegate = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public API

    /// Reloads the sidebar with a new list of day summaries.
    ///
    /// If the previously selected day no longer appears in `summaries`, the selection is cleared
    /// and `selectedDayString` is set to nil. Otherwise the existing selection is preserved.
    func reloadDays(_ summaries: [ActivityDaySummary]) {
        let prevDay = selectedDayString
        days = summaries
        suppressDelegate = true
        tableView.reloadData()
        if let prev = prevDay,
           let idx = days.firstIndex(where: { $0.dayString == prev }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            selectedDayString = prev
        } else if prevDay != nil {
            tableView.deselectAll(nil)
            selectedDayString = nil
        }
        suppressDelegate = false
        updateFooter()
    }

    /// Selects the row for the given day string programmatically (does NOT fire delegate).
    func selectDay(_ dayString: String, notify: Bool = false) {
        guard let idx = days.firstIndex(where: { $0.dayString == dayString }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
        selectedDayString = dayString
        if notify { delegate?.sidebarDidSelectDay(dayString) }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { days.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { nil }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarRowView
                    ?? SidebarRowView(identifier: id)
        cell.configure(with: days[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 44 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressDelegate else { return }
        let row = tableView.selectedRow
        guard row >= 0 else {
            selectedDayString = nil
            return
        }
        let dayString = days[row].dayString
        selectedDayString = dayString
        delegate?.sidebarDidSelectDay(dayString)
    }

    // MARK: - Build UI

    private func buildUI() {
        // Table column
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("day"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.menuProvider = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byWordWrapping

        addSubview(scrollView)
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            footerLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            footerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    // MARK: - Footer

    private func updateFooter() {
        let totalEvents = days.reduce(0) { $0 + $1.eventCount }
        let logsBytes = days.reduce(Int64(0)) { $0 + $1.logFileSizeBytes }
        let screenshotsBytes = days.reduce(Int64(0)) { $0 + $1.screenshotFolderSizeBytes }
        footerLabel.stringValue = "\(days.count) days  •  \(totalEvents) events\nlogs: \(Self.formatBytes(logsBytes))  •  screenshots: \(Self.formatBytes(screenshotsBytes))"
    }

    // MARK: - Context menu

    /// Builds the row-level context menu for a sidebar row.
    func makeContextMenu(forRow row: Int) -> NSMenu? {
        guard row < days.count else { return nil }
        let dayString = days[row].dayString
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Delete This Day's Data",
            action: #selector(requestDeleteDay(_:)),
            keyEquivalent: ""
        )
        item.representedObject = dayString
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func requestDeleteDay(_ sender: NSMenuItem) {
        guard let dayString = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestDeleteDay(dayString)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Sidebar row cell

private final class SidebarRowView: NSTableCellView {

    private let dayLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func configure(with summary: ActivityDaySummary) {
        dayLabel.stringValue = Self.formattedDay(summary.dayString)
        countLabel.stringValue = "\(summary.eventCount) events"
        storageLabel.stringValue = ActivityHistorySidebarView.formatBytes(summary.totalSizeBytes)
    }

    private func buildUI() {
        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        dayLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        storageLabel.translatesAutoresizingMaskIntoConstraints = false
        storageLabel.font = NSFont.systemFont(ofSize: 10)
        storageLabel.textColor = .tertiaryLabelColor
        storageLabel.alignment = .right
        storageLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dayLabel)
        addSubview(countLabel)
        addSubview(storageLabel)

        NSLayoutConstraint.activate([
            dayLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            dayLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            countLabel.topAnchor.constraint(equalTo: dayLabel.bottomAnchor, constant: 2),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            countLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            storageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            storageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private static func formattedDay(_ dayString: String) -> String {
        guard let date = ActivityLogPaths.date(fromDayString: dayString) else { return dayString }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
