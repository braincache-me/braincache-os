import AppKit

final class ImportExportPrefsView: NSView {

    var clipStore: ClipStore? {
        didSet {
            importFromPasteButton.isEnabled = clipStore != nil
            repairSearchIndexButton.isEnabled = clipStore != nil
        }
    }

    private let importFromPasteButton = NSButton(title: "Import from Paste…", target: nil, action: nil)
    private let exportBackupButton = NSButton(title: "Export BrainCache Backup…", target: nil, action: nil)
    private let importBackupButton = NSButton(title: "Import BrainCache Backup…", target: nil, action: nil)
    private let importExistingDatabaseButton = NSButton(title: "Import Existing Database…", target: nil, action: nil)
    private let repairSearchIndexButton = NSButton(title: "Repair Search Index", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        importFromPasteButton.isEnabled = false
        repairSearchIndexButton.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func buildUI() {
        importFromPasteButton.target = self
        importFromPasteButton.action = #selector(importFromPaste)

        exportBackupButton.target = self
        exportBackupButton.action = #selector(exportBackup)

        importBackupButton.target = self
        importBackupButton.action = #selector(importBackup)

        importExistingDatabaseButton.target = self
        importExistingDatabaseButton.action = #selector(importExistingDatabase)

        repairSearchIndexButton.target = self
        repairSearchIndexButton.action = #selector(repairSearchIndex)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 24
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(makeSection(
            title: "Import from Paste",
            description: "Import clipboard history directly from the Paste app database.",
            content: importFromPasteButton
        ))

        rootStack.addArrangedSubview(makeSection(
            title: "BrainCache Backup",
            description: "Export a full backup package that includes the SQLite database and media files. Importing a backup replaces your current local BrainCache data on the next launch.",
            content: makeButtonRow(exportBackupButton, importBackupButton)
        ))

        rootStack.addArrangedSubview(makeSection(
            title: "Recovery",
            description: "If your old history is on disk but not appearing, rebuild the search index or import an existing ClipVault/BrainCache data folder or clipvault.db file.",
            content: makeButtonRow(repairSearchIndexButton, importExistingDatabaseButton)
        ))

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    private func makeSection(title: String, description: String, content: NSView) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.preferredMaxLayoutWidth = 440

        let stack = NSStackView(views: [titleLabel, descriptionLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func makeButtonRow(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    @objc private func importFromPaste() {
        guard let clipStore else { return }
        ImportExportCoordinator.shared.importFromPaste(clipStore: clipStore)
    }

    @objc private func exportBackup() {
        ImportExportCoordinator.shared.exportClipVaultBackup()
    }

    @objc private func importBackup() {
        ImportExportCoordinator.shared.importClipVaultBackup()
    }

    @objc private func importExistingDatabase() {
        ImportExportCoordinator.shared.importExistingDatabase()
    }

    @objc private func repairSearchIndex() {
        ImportExportCoordinator.shared.repairSearchIndex()
    }
}
