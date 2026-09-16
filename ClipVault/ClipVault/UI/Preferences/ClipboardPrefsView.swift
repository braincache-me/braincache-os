import AppKit

final class ClipboardPrefsView: NSView {

    var clipStore: ClipStore?

    // MARK: - History controls

    private let maxHistoryField = NSTextField()
    private let maxHistoryStepper = NSStepper()
    private let purgeAgeDaysField = NSTextField()
    private let purgeAgeDaysStepper = NSStepper()

    // MARK: - Storage controls

    private let dbSizeLabel = NSTextField(labelWithString: "Database size: —")
    private let clearButton = NSButton(title: "Clear All History…", target: nil, action: nil)

    // MARK: - Exclusion table

    private let exclusionTableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)

    private var excludedBundleIDs: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Build UI

    private func buildUI() {
        // History
        maxHistoryField.formatter = NumberFormatter()
        maxHistoryField.delegate = self
        maxHistoryStepper.minValue = 100
        maxHistoryStepper.maxValue = 50_000
        maxHistoryStepper.increment = 100
        maxHistoryStepper.valueWraps = false
        maxHistoryStepper.target = self
        maxHistoryStepper.action = #selector(maxHistoryStepperChanged(_:))

        purgeAgeDaysField.formatter = NumberFormatter()
        purgeAgeDaysField.delegate = self
        purgeAgeDaysStepper.minValue = 1
        purgeAgeDaysStepper.maxValue = 3650
        purgeAgeDaysStepper.increment = 1
        purgeAgeDaysStepper.valueWraps = false
        purgeAgeDaysStepper.target = self
        purgeAgeDaysStepper.action = #selector(purgeAgeStepperChanged(_:))

        // Storage
        clearButton.target = self
        clearButton.action = #selector(clearAllHistory)

        // Exclusions table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.title = "Excluded App Bundle IDs"
        column.isEditable = false
        exclusionTableView.addTableColumn(column)
        exclusionTableView.headerView = NSTableHeaderView()
        exclusionTableView.delegate = self
        exclusionTableView.dataSource = self
        exclusionTableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = exclusionTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        addButton.target = self
        addButton.action = #selector(addExclusion)
        removeButton.target = self
        removeButton.action = #selector(removeExclusion)

        // Layout
        let m: CGFloat = 20
        let lw: CGFloat = 180

        let historyHeader = makeSectionHeader("History")
        let maxHistoryLabel = NSTextField(labelWithString: "Max history count:")
        let purgeAgeLabel = NSTextField(labelWithString: "Auto-purge after (days):")
        let sep1 = makeSeparator()
        let storageHeader = makeSectionHeader("Storage")
        let sep2 = makeSeparator()
        let exclusionHeader = makeSectionHeader("Excluded Apps")
        let exclusionDesc = NSTextField(wrappingLabelWithString:
            "Clipboard changes from these apps are ignored. Bundle ID format, e.g. com.1password.1password.")
        exclusionDesc.font = .systemFont(ofSize: 11)
        exclusionDesc.textColor = .secondaryLabelColor
        exclusionDesc.maximumNumberOfLines = 0

        let allViews: [NSView] = [
            historyHeader, maxHistoryLabel, maxHistoryField, maxHistoryStepper,
            purgeAgeLabel, purgeAgeDaysField, purgeAgeDaysStepper,
            sep1, storageHeader, dbSizeLabel, clearButton,
            sep2, exclusionHeader, exclusionDesc, scrollView, addButton, removeButton,
        ]
        allViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            historyHeader.topAnchor.constraint(equalTo: topAnchor, constant: m),
            historyHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),

            maxHistoryLabel.topAnchor.constraint(equalTo: historyHeader.bottomAnchor, constant: 10),
            maxHistoryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            maxHistoryLabel.widthAnchor.constraint(equalToConstant: lw),

            maxHistoryField.centerYAnchor.constraint(equalTo: maxHistoryLabel.centerYAnchor),
            maxHistoryField.leadingAnchor.constraint(equalTo: maxHistoryLabel.trailingAnchor, constant: 8),
            maxHistoryField.widthAnchor.constraint(equalToConstant: 80),

            maxHistoryStepper.centerYAnchor.constraint(equalTo: maxHistoryLabel.centerYAnchor),
            maxHistoryStepper.leadingAnchor.constraint(equalTo: maxHistoryField.trailingAnchor, constant: 4),

            purgeAgeLabel.topAnchor.constraint(equalTo: maxHistoryLabel.bottomAnchor, constant: 10),
            purgeAgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            purgeAgeLabel.widthAnchor.constraint(equalToConstant: lw),

            purgeAgeDaysField.centerYAnchor.constraint(equalTo: purgeAgeLabel.centerYAnchor),
            purgeAgeDaysField.leadingAnchor.constraint(equalTo: purgeAgeLabel.trailingAnchor, constant: 8),
            purgeAgeDaysField.widthAnchor.constraint(equalToConstant: 80),

            purgeAgeDaysStepper.centerYAnchor.constraint(equalTo: purgeAgeLabel.centerYAnchor),
            purgeAgeDaysStepper.leadingAnchor.constraint(equalTo: purgeAgeDaysField.trailingAnchor, constant: 4),

            sep1.topAnchor.constraint(equalTo: purgeAgeLabel.bottomAnchor, constant: 16),
            sep1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            sep1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),

            storageHeader.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 8),
            storageHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),

            dbSizeLabel.topAnchor.constraint(equalTo: storageHeader.bottomAnchor, constant: 10),
            dbSizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),

            clearButton.topAnchor.constraint(equalTo: dbSizeLabel.bottomAnchor, constant: 8),
            clearButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),

            sep2.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 16),
            sep2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            sep2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),

            exclusionHeader.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 8),
            exclusionHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),

            exclusionDesc.topAnchor.constraint(equalTo: exclusionHeader.bottomAnchor, constant: 4),
            exclusionDesc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            exclusionDesc.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),

            scrollView.topAnchor.constraint(equalTo: exclusionDesc.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            addButton.widthAnchor.constraint(equalToConstant: 28),

            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.widthAnchor.constraint(equalToConstant: 28),

            bottomAnchor.constraint(greaterThanOrEqualTo: removeButton.bottomAnchor, constant: m),
        ])
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Load / Refresh

    private func loadValues() {
        let s = Settings.shared
        maxHistoryField.integerValue = s.maxHistoryCount
        maxHistoryStepper.intValue = Int32(s.maxHistoryCount)
        purgeAgeDaysField.integerValue = s.autoPurgeAgeDays
        purgeAgeDaysStepper.intValue = Int32(s.autoPurgeAgeDays)
    }

    func refresh() {
        refreshDBSize()
        refreshExclusionList()
    }

    func refreshDBSize() {
        if let url = try? DatabaseManager.databaseURL(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            let kb = size / 1024
            dbSizeLabel.stringValue = "Database size: \(kb) KB"
        } else {
            dbSizeLabel.stringValue = "Database size: —"
        }
    }

    func refreshExclusionList() {
        excludedBundleIDs = Settings.shared.excludedBundleIDs
        exclusionTableView.reloadData()
    }

    // MARK: - Actions

    @objc private func maxHistoryStepperChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        maxHistoryField.integerValue = value
        Settings.shared.maxHistoryCount = value
    }

    @objc private func purgeAgeStepperChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        purgeAgeDaysField.integerValue = value
        Settings.shared.autoPurgeAgeDays = value
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all clipboard history. Pinned clips will also be removed. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                try? self?.clipStore?.deleteAll()
            }
        }
    }

    @objc private func addExclusion() {
        let alert = NSAlert()
        alert.messageText = "Add Excluded App"
        alert.informativeText = "Enter the bundle identifier of the app to exclude (e.g. com.1password.1password):"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "com.example.AppName"
        alert.accessoryView = input

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let bundleID = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { return }
            self?.addBundleID(bundleID)
        }
    }

    @objc private func removeExclusion() {
        let row = exclusionTableView.selectedRow
        guard row >= 0, row < excludedBundleIDs.count else { return }
        removeBundleID(at: row)
    }

    // MARK: - Mutation helpers (internal for testing)

    func addBundleID(_ bundleID: String) {
        guard !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
        Settings.shared.excludedBundleIDs = excludedBundleIDs
        exclusionTableView.reloadData()
    }

    func removeBundleID(at index: Int) {
        guard index >= 0, index < excludedBundleIDs.count else { return }
        excludedBundleIDs.remove(at: index)
        Settings.shared.excludedBundleIDs = excludedBundleIDs
        exclusionTableView.reloadData()
    }
}

// MARK: - NSTextFieldDelegate

extension ClipboardPrefsView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === maxHistoryField {
            let v = max(100, min(50_000, field.integerValue))
            field.integerValue = v
            maxHistoryStepper.integerValue = v
            Settings.shared.maxHistoryCount = v
        } else if field === purgeAgeDaysField {
            let v = max(1, min(3650, field.integerValue))
            field.integerValue = v
            purgeAgeDaysStepper.integerValue = v
            Settings.shared.autoPurgeAgeDays = v
        }
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ClipboardPrefsView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return excludedBundleIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = id
            let textField = NSTextField()
            textField.isEditable = false
            textField.isBordered = false
            textField.drawsBackground = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell?.addSubview(textField)
            cell?.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }
        cell?.textField?.stringValue = excludedBundleIDs[row]
        return cell
    }
}
