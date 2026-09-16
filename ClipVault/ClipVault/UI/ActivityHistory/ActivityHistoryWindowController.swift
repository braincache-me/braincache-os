import AppKit

final class ActivityHistoryWindowController: NSWindowController,
                                              ActivityHistorySidebarDelegate,
                                              ActivityTimelineDelegate,
                                              NSSplitViewDelegate {

    static let shared = ActivityHistoryWindowController()

    // MARK: - Export

    private let exportCoordinator = ActivityExportCoordinator()

    // MARK: - Subviews

    private let horizontalSplit = NSSplitView()
    private let verticalSplit = NSSplitView()

    private let sidebarView = ActivityHistorySidebarView()
    private let timelineView = ActivityTimelineView()
    private let detailView = ActivityEventDetailView()

    // MARK: - Store

    var store: ActivityHistoryStore?

    // MARK: - Init

    private init() {
        // .miniaturizable is intentionally omitted: BrainCache is LSUIElement = true,
        // so a minimised window goes to the Dock with no app icon to click on,
        // leaving the user no way to restore it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Activity History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)

        buildUI()
        wireCallbacks()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Show

    func show() {
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        store?.refreshDayList()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let window else { return }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let totalWidth = contentRect.width
        let totalHeight = contentRect.height
        let sidebarWidth: CGFloat = 200
        let timelineHeight: CGFloat = totalHeight * 0.55

        // Horizontal split: sidebar | right pane
        horizontalSplit.isVertical = true
        horizontalSplit.dividerStyle = .thin
        horizontalSplit.delegate = self
        horizontalSplit.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        horizontalSplit.autoresizingMask = [.width, .height]

        // Vertical split (right pane): timeline | detail
        verticalSplit.isVertical = false
        verticalSplit.dividerStyle = .thin
        let rightWidth = totalWidth - sidebarWidth - horizontalSplit.dividerThickness
        verticalSplit.frame = NSRect(x: 0, y: 0, width: rightWidth, height: totalHeight)

        // Give subviews real initial frames
        sidebarView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: totalHeight)
        sidebarView.delegate = self

        timelineView.frame = NSRect(x: 0, y: 0, width: rightWidth, height: timelineHeight)
        timelineView.delegate = self

        let detailHeight = totalHeight - timelineHeight - verticalSplit.dividerThickness
        detailView.frame = NSRect(x: 0, y: 0, width: rightWidth, height: detailHeight)

        // Right pane: timeline on top, detail on bottom
        verticalSplit.addSubview(timelineView)
        verticalSplit.addSubview(detailView)
        verticalSplit.adjustSubviews()

        // Horizontal split: sidebar on left, right pane on right
        horizontalSplit.addSubview(sidebarView)
        horizontalSplit.addSubview(verticalSplit)
        horizontalSplit.adjustSubviews()

        // Wrap in a visual-effect view so the window is semi-transparent,
        // matching the Chat and Search panels.
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.autoresizingMask = [.width, .height]
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        // With fullSizeContentView the title bar is overlaid on the content,
        // so inset the split view down by the title-bar height to keep
        // sidebar/timeline content clear of the traffic-light buttons.
        let titleBarInset: CGFloat = 28
        horizontalSplit.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(horizontalSplit)
        NSLayoutConstraint.activate([
            horizontalSplit.topAnchor.constraint(equalTo: effectView.topAnchor, constant: titleBarInset),
            horizontalSplit.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            horizontalSplit.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            horizontalSplit.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        window.contentView = effectView
    }

    private func wireCallbacks() {
        timelineView.onExport = { [weak self] in
            self?.runExport()
        }
    }

    // MARK: - Store callbacks

    func connectStore() {
        store?.onDataChanged = { [weak self] in
            self?.handleDataChanged()
        }
    }

    private func handleDataChanged() {
        sidebarView.reloadDays(store?.days ?? [])

        if sidebarView.selectedDayString != nil {
            let events = store?.loadedEvents ?? []
            if events.isEmpty, let error = store?.lastError {
                timelineView.showError(error)
            } else {
                timelineView.loadEvents(events)
                timelineView.reloadAppFilter(apps: store?.availableApps ?? [])
            }
        } else if let error = store?.lastError, (store?.days ?? []).isEmpty {
            timelineView.showError(error)
        } else {
            timelineView.showEmptyDay()
            detailView.configure(event: nil, rawJSON: "", screenshotURL: nil)
        }
    }

    // MARK: - ActivityHistorySidebarDelegate

    func sidebarDidSelectDay(_ dayString: String) {
        store?.loadDay(dayString)
        timelineView.loadEvents([])
        detailView.configure(event: nil, rawJSON: "", screenshotURL: nil)
    }

    // MARK: - ActivityTimelineDelegate

    func timelineDidSelectEvent(_ event: ActivityEvent?) {
        guard let event else {
            detailView.configure(event: nil, rawJSON: "", screenshotURL: nil)
            return
        }
        let rawJSON = store?.rawJSON(for: event) ?? ""
        let screenshotURL = event.screenshotPath.flatMap { store?.screenshotURL(relativePath: $0) }
        detailView.configure(event: event, rawJSON: rawJSON, screenshotURL: screenshotURL)
    }

    // MARK: - Export

    private func runExport() {
        guard let dayString = sidebarView.selectedDayString else { return }
        let explicit = timelineView.tableView.selectedRowIndexes
        let events: [ActivityEvent]
        if !explicit.isEmpty {
            events = timelineView.selectedEvents
        } else {
            events = store?.loadedEvents ?? []
        }
        guard !events.isEmpty else { return }
        exportCoordinator.run(
            events: events,
            dayString: dayString,
            screenshotsURL: store?.screenshotRootURL,
            parentWindow: window
        )
    }

    // MARK: - ActivityHistorySidebarDelegate: delete day

    func sidebarDidRequestDeleteDay(_ dayString: String) {
        let alert = NSAlert()
        alert.messageText = "Delete \(dayString) Data?"
        alert.informativeText = "The log and screenshots for this day will be moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store?.deleteDay(dayString) { error in
            if let error {
                DispatchQueue.main.async {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === horizontalSplit { return 150 }
        return 150
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === horizontalSplit { return 320 }
        if splitView === verticalSplit {
            return splitView.bounds.height - 150
        }
        return proposedMaximumPosition
    }
}
