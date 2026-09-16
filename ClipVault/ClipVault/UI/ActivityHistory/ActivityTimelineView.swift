import AppKit

/// Protocol for notifying the owner when a timeline event is selected.
protocol ActivityTimelineDelegate: AnyObject {
    func timelineDidSelectEvent(_ event: ActivityEvent?)
}

/// Right-panel timeline for the Activity History window.
///
/// Displays a filtered list of `ActivityEvent` rows for the selected day.
/// Hosts a search field, app filter popup, and event-type filter popup in a
/// compact control bar at the top.
final class ActivityTimelineView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    // MARK: - Subviews

    private let searchField = NSSearchField()
    private let appFilterPopup = NSPopUpButton()
    private let typeFilterPopup = NSPopUpButton()
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let controlBar = NSStackView()

    private let scrollView = NSScrollView()
    let tableView = NSTableView()

    private let emptyDayLabel = NSTextField(labelWithString: "Select a day in the sidebar")
    private let noResultsLabel = NSTextField(labelWithString: "No matching events")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - State

    weak var delegate: ActivityTimelineDelegate?
    var onExport: (() -> Void)?

    /// The full (unfiltered) events for the selected day.
    private var allEvents: [ActivityEvent] = []
    /// The events currently shown in the table (after filtering).
    private(set) var filteredEvents: [ActivityEvent] = []

    private var currentFilter = ActivityHistoryFilter()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public API

    /// Loads a new set of events for the selected day and applies the current filter.
    func loadEvents(_ events: [ActivityEvent]) {
        allEvents = events
        reapplyFilter()
        emptyDayLabel.isHidden = true
        errorLabel.isHidden = true
        noResultsLabel.isHidden = !filteredEvents.isEmpty || !allEvents.isEmpty
    }

    /// Shows the empty-day placeholder (no day selected yet).
    func showEmptyDay() {
        allEvents = []
        filteredEvents = []
        tableView.reloadData()
        emptyDayLabel.isHidden = false
        errorLabel.isHidden = true
        noResultsLabel.isHidden = true
    }

    /// Shows an error message in the timeline area.
    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        emptyDayLabel.isHidden = true
        noResultsLabel.isHidden = true
    }

    /// Reloads the available app names in the app-filter popup.
    func reloadAppFilter(apps: [String]) {
        let currentTitle = appFilterPopup.selectedItem?.title
        appFilterPopup.removeAllItems()
        appFilterPopup.addItem(withTitle: "All Apps")
        for app in apps { appFilterPopup.addItem(withTitle: app) }
        if let title = currentTitle,
           let item = appFilterPopup.item(withTitle: title) {
            appFilterPopup.select(item)
        } else {
            appFilterPopup.selectItem(at: 0)
        }
    }

    /// Returns the currently selected events (for export).
    var selectedEvents: [ActivityEvent] {
        let rows = tableView.selectedRowIndexes
        if rows.isEmpty { return filteredEvents }
        return rows.compactMap { idx in
            guard idx < filteredEvents.count else { return nil }
            return filteredEvents[idx]
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEvents.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { nil }

    /// Drag source: provide a plain-text representation of the dragged event row.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < filteredEvents.count else { return nil }
        let text = ActivityExportFormatter.plainTextString(for: [filteredEvents[row]])
        return text as NSString
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ActivityEventRowView.identifier, owner: nil) as? ActivityEventRowView
                    ?? ActivityEventRowView(frame: .zero)
        cell.identifier = ActivityEventRowView.identifier
        cell.configure(with: filteredEvents[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 44 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let event = row >= 0 && row < filteredEvents.count ? filteredEvents[row] : nil
        delegate?.timelineDidSelectEvent(event)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        currentFilter.searchText = searchField.stringValue
        reapplyFilter()
    }

    // MARK: - Control bar actions

    @objc private func appFilterChanged() {
        let idx = appFilterPopup.indexOfSelectedItem
        currentFilter.appName = idx == 0 ? nil : appFilterPopup.selectedItem?.title
        reapplyFilter()
    }

    @objc private func typeFilterChanged() {
        let idx = typeFilterPopup.indexOfSelectedItem
        if idx == 0 {
            currentFilter.eventType = nil
        } else {
            let allTypes = ActivityEventType.allCases
            let typeIdx = idx - 1
            currentFilter.eventType = typeIdx < allTypes.count ? allTypes[typeIdx] : nil
        }
        reapplyFilter()
    }

    @objc private func exportTapped() {
        onExport?()
    }

    // MARK: - Filter

    private func reapplyFilter() {
        let previouslySelectedEvent: ActivityEvent? = {
            let row = tableView.selectedRow
            guard row >= 0, row < filteredEvents.count else { return nil }
            return filteredEvents[row]
        }()

        filteredEvents = allEvents.filter { event in
            if let app = currentFilter.appName, !app.isEmpty {
                guard event.appName == app else { return false }
            }
            if let type_ = currentFilter.eventType {
                guard event.eventType == type_ else { return false }
            }
            if !currentFilter.searchText.isEmpty {
                let text = currentFilter.searchText.lowercased()
                let haystack = [
                    event.appName,
                    event.windowTitle,
                    event.controlName ?? "",
                    event.controlRole ?? "",
                    event.controlValue ?? "",
                    event.triggerMetadata ?? ""
                ].joined(separator: " ").lowercased()
                guard haystack.contains(text) else { return false }
            }
            return true
        }
        tableView.reloadData()

        if let prev = previouslySelectedEvent,
           let idx = filteredEvents.firstIndex(where: { $0.id == prev.id }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }

        noResultsLabel.isHidden = !filteredEvents.isEmpty || allEvents.isEmpty
        emptyDayLabel.isHidden = !allEvents.isEmpty || !filteredEvents.isEmpty
        errorLabel.isHidden = true
    }

    // MARK: - Build UI

    private func buildUI() {
        // Control bar
        searchField.placeholderString = "Search events"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        appFilterPopup.addItem(withTitle: "All Apps")
        appFilterPopup.target = self
        appFilterPopup.action = #selector(appFilterChanged)

        typeFilterPopup.addItem(withTitle: "All Types")
        for type_ in ActivityEventType.allCases {
            typeFilterPopup.addItem(withTitle: type_.rawValue)
        }
        typeFilterPopup.target = self
        typeFilterPopup.action = #selector(typeFilterChanged)

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportTapped)

        controlBar.orientation = .horizontal
        controlBar.spacing = 8
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        controlBar.addArrangedSubview(searchField)
        controlBar.addArrangedSubview(appFilterPopup)
        controlBar.addArrangedSubview(typeFilterPopup)
        controlBar.addArrangedSubview(exportButton)

        // Table
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state labels
        emptyDayLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyDayLabel.font = NSFont.systemFont(ofSize: 13)
        emptyDayLabel.textColor = .tertiaryLabelColor
        emptyDayLabel.alignment = .center

        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.font = NSFont.systemFont(ofSize: 13)
        noResultsLabel.textColor = .tertiaryLabelColor
        noResultsLabel.alignment = .center
        noResultsLabel.isHidden = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 3

        addSubview(controlBar)
        addSubview(scrollView)
        addSubview(emptyDayLabel)
        addSubview(noResultsLabel)
        addSubview(errorLabel)

        // Search field should expand
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            controlBar.topAnchor.constraint(equalTo: topAnchor),
            controlBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: controlBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyDayLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyDayLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            noResultsLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noResultsLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40)
        ])
    }
}
