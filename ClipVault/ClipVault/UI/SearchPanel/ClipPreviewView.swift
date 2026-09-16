import AppKit

/// A simple preview view shown below the table for the selected clip.
final class ClipPreviewView: NSView {

    private let textView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = tv
        return scroll
    }()

    private var textViewContent: NSTextView? {
        textView.documentView as? NSTextView
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    private func setupSubviews() {
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func show(record: ClipRecord?) {
        guard let record = record, let tv = textViewContent else {
            textViewContent?.string = ""
            return
        }
        guard let text = record.textContent, !text.isEmpty else {
            tv.string = "[Binary content — no text preview]"
            return
        }
        tv.string = text
    }
}
