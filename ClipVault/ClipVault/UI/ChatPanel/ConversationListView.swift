import AppKit

// MARK: - Delegate Protocol

protocol ConversationListViewDelegate: AnyObject {
    func conversationListViewDidRequestNewChat(_ view: ConversationListView)
    func conversationListView(_ view: ConversationListView, didSelectConversation id: Int64)
    func conversationListView(_ view: ConversationListView, didDeleteConversation id: Int64)
    func conversationListView(_ view: ConversationListView, didRenameConversation id: Int64, newTitle: String)
    func conversationListViewDidRequestClearAll(_ view: ConversationListView)
}

// MARK: - ConversationListView

/// Left sidebar listing all persisted conversations with New Chat and Clear All controls.
final class ConversationListView: NSView {

    weak var delegate: ConversationListViewDelegate?

    private(set) var conversations: [ConversationRecord] = []
    private(set) var selectedConversationId: Int64?

    private var tableView: NSTableView!

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(frame:)") }

    // MARK: - Layout

    private func buildLayout() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        // New Chat button
        let newBtn = NSButton()
        newBtn.translatesAutoresizingMaskIntoConstraints = false
        newBtn.title = "New Chat"
        newBtn.image = NSImage(systemSymbolName: "square.and.pencil",
                               accessibilityDescription: "New Chat")
        newBtn.imagePosition = .imageLeading
        newBtn.imageHugsTitle = true
        newBtn.bezelStyle = .rounded
        newBtn.font = .systemFont(ofSize: 12, weight: .medium)
        newBtn.alignment = .left
        newBtn.contentTintColor = .labelColor
        newBtn.target = self
        newBtn.action = #selector(newChatTapped)
        addSubview(newBtn)

        // Conversation table
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        col.resizingMask = .autoresizingMask

        let tv = NSTableView()
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.rowHeight = 48
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .regular
        tv.gridStyleMask = []
        tv.intercellSpacing = NSSize(width: 0, height: 1)
        tv.dataSource = self
        tv.delegate = self
        tableView = tv

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.scrollerStyle = .overlay
        addSubview(sv)

        // Clear All button
        let clearBtn = NSButton()
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.title = "Clear All"
        clearBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear All")
        clearBtn.imagePosition = .imageLeading
        clearBtn.imageHugsTitle = true
        clearBtn.bezelStyle = .rounded
        clearBtn.font = .systemFont(ofSize: 12)
        clearBtn.alignment = .left
        clearBtn.contentTintColor = .secondaryLabelColor
        clearBtn.target = self
        clearBtn.action = #selector(clearAllTapped)
        addSubview(clearBtn)

        NSLayoutConstraint.activate([
            newBtn.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            newBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            newBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newBtn.heightAnchor.constraint(equalToConstant: 30),

            sv.topAnchor.constraint(equalTo: newBtn.bottomAnchor, constant: 10),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: clearBtn.topAnchor, constant: -10),

            clearBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            clearBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clearBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            clearBtn.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Public API

    /// Reload the list with new data. `selectedId: nil` deselects all rows.
    /// If `selectedId` does not match any conversation, `selectedConversationId` is set to nil.
    func reload(conversations: [ConversationRecord], selectedId: Int64?) {
        self.conversations = conversations
        // Only mark as selected if the id actually exists in the list.
        if let id = selectedId, conversations.contains(where: { $0.id == id }) {
            self.selectedConversationId = id
        } else {
            self.selectedConversationId = nil
        }
        tableView.reloadData()
        if let id = selectedConversationId,
           let idx = conversations.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - Relative date helper (internal for testability)

    static func relativeDate(from timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours) hr ago" }
        if hours < 48 { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - Actions

    @objc private func newChatTapped() {
        delegate?.conversationListViewDidRequestNewChat(self)
    }

    @objc private func clearAllTapped() {
        delegate?.conversationListViewDidRequestClearAll(self)
    }
}

// MARK: - NSTableViewDataSource

extension ConversationListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        conversations.count
    }
}

// MARK: - Reusable Cell View

/// Reusable cell view for the conversation list table, avoiding per-row allocation on scroll.
private final class ConversationCellView: NSTableCellView {

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ConversationCellView")
    static var identifier: NSUserInterfaceItemIdentifier { cellIdentifier }

    let titleLabel = NSTextField(labelWithString: "")
    let dateLabel  = NSTextField(labelWithString: "")
    let deleteBtn  = NSButton()
    private var convId: Int64?
    private weak var listOwner: ConversationListView?
    private var deleteTarget: ActionTarget?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.cellIdentifier

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .secondaryLabelColor

        deleteBtn.translatesAutoresizingMaskIntoConstraints = false
        deleteBtn.bezelStyle = .inline
        deleteBtn.isBordered = false
        deleteBtn.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                  accessibilityDescription: "Delete")
        deleteBtn.imageScaling = .scaleProportionallyDown
        deleteBtn.contentTintColor = .tertiaryLabelColor
        deleteBtn.toolTip = "Delete conversation"
        deleteBtn.alphaValue = 0

        addSubview(titleLabel)
        addSubview(dateLabel)
        addSubview(deleteBtn)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),

            deleteBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            deleteBtn.widthAnchor.constraint(equalToConstant: 16),
            deleteBtn.heightAnchor.constraint(equalToConstant: 16),

            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(frame:)") }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            deleteBtn.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            deleteBtn.animator().alphaValue = 0
        }
    }

    func configure(with conv: ConversationRecord, owner: ConversationListView) {
        titleLabel.stringValue = conv.title
        dateLabel.stringValue = ConversationListView.relativeDate(from: conv.updatedAt)
        convId = conv.id
        listOwner = owner

        let target = ActionTarget { [weak self, weak owner] in
            guard let self, let owner, let id = self.convId else { return }
            owner.delegate?.conversationListView(owner, didDeleteConversation: id)
        }
        deleteTarget = target
        deleteBtn.target = target
        deleteBtn.action = #selector(ActionTarget.run)

        let menu = NSMenu()
        if let convId = conv.id {
            let renameItem = NSMenuItem(title: "Rename…",
                                        action: #selector(ConversationListView.contextMenuRename(_:)),
                                        keyEquivalent: "")
            renameItem.representedObject = NSNumber(value: convId)
            renameItem.target = owner
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(title: "Delete",
                                        action: #selector(ConversationListView.contextMenuDelete(_:)),
                                        keyEquivalent: "")
            deleteItem.representedObject = NSNumber(value: convId)
            deleteItem.target = owner
            menu.addItem(deleteItem)
        }
        self.menu = menu
    }
}

// MARK: - NSTableViewDelegate

extension ConversationListView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < conversations.count else { return nil }
        let conv = conversations[row]

        let cell: ConversationCellView
        if let reused = tableView.makeView(withIdentifier: ConversationCellView.identifier,
                                           owner: self) as? ConversationCellView {
            cell = reused
        } else {
            cell = ConversationCellView(frame: .zero)
        }
        cell.configure(with: conv, owner: self)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < conversations.count else {
            selectedConversationId = nil
            return
        }
        let conv = conversations[row]
        selectedConversationId = conv.id
        if let id = conv.id {
            delegate?.conversationListView(self, didSelectConversation: id)
        }
    }

    @objc func contextMenuDelete(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = number.int64Value
        delegate?.conversationListView(self, didDeleteConversation: id)
    }

    @objc func contextMenuRename(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = number.int64Value
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        delegate?.conversationListView(self, didRenameConversation: id, newTitle: conv.title)
    }
}
