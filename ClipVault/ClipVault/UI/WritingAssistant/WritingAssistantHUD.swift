import AppKit
import QuartzCore

/// A small, non-activating floating panel used by the Writing Assistant to show
/// transient status beside the caret. Minimalist: a compact translucent pill
/// that holds an animated loader during work and morphs into a checkmark on success.
final class WritingAssistantHUD {

    static let shared = WritingAssistantHUD()

    private static let compactSize = NSSize(width: 42, height: 42)
    private static let backgroundOpacity: CGFloat = 0.72

    private var panel: NSPanel?
    private var background: NSVisualEffectView?
    private let iconView = NSImageView()
    private let loaderView = WritingAssistantLoaderView()
    private let label = NSTextField(labelWithString: "")
    private var currentMode: Mode = .hidden
    private var dismissWorkItem: DispatchWorkItem?

    private enum Mode { case hidden, progress, success, error }

    private init() {}

    /// Shows a quiet loader that stays until replaced or hidden.
    func showProgress(_ message: String, near anchor: CGRect?) {
        present(mode: .progress, message: nil, anchor: anchor, autoDismiss: nil)
    }

    /// Morphs the loader into a checkmark; no text. Auto-dismisses.
    func showSuccess(_ message: String, near anchor: CGRect?) {
        present(mode: .success, message: nil, anchor: anchor, autoDismiss: 1.4)
    }

    /// Shows an error with a brief message — errors need explanation.
    func showError(_ message: String, near anchor: CGRect?) {
        present(mode: .error, message: message, anchor: anchor, autoDismiss: 5.5)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentMode = .hidden
        panel?.orderOut(nil)
    }

    private func present(
        mode: Mode,
        message: String?,
        anchor: CGRect?,
        autoDismiss: TimeInterval?
    ) {
        let resolvedAnchor = anchor ?? Self.activeScreenFrame()
        let panel = ensurePanel()
        let previousMode = currentMode
        currentMode = mode

        switch mode {
        case .progress:
            configureProgress()
        case .success:
            configureSuccess(animatingFrom: previousMode)
        case .error:
            configureError(message: message ?? "")
        case .hidden:
            break
        }

        let size = preferredSize(for: mode)
        panel.setContentSize(size)
        background?.layer?.cornerRadius = min(size.width, size.height) / 2
        position(panel, size: size, near: resolvedAnchor)

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissWorkItem?.cancel()
        if let autoDismiss {
            let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoDismiss, execute: work)
        } else {
            dismissWorkItem = nil
        }
    }

    // MARK: - Mode configuration

    private func configureProgress() {
        label.isHidden = true
        iconView.isHidden = true
        iconView.alphaValue = 0
        loaderView.isHidden = false
        loaderView.alphaValue = 1
        Self.resetLayerTransform(loaderView)
        loaderView.startAnimating()
    }

    private func configureSuccess(animatingFrom previous: Mode) {
        label.isHidden = true
        iconView.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Rewritten")
        iconView.contentTintColor = .systemGreen
        iconView.isHidden = false

        if previous == .progress {
            morphLoaderIntoCheck()
        } else {
            loaderView.stopAnimating()
            loaderView.isHidden = true
            loaderView.alphaValue = 1
            iconView.alphaValue = 1
            Self.resetLayerTransform(iconView)
        }
    }

    private func configureError(message: String) {
        loaderView.stopAnimating()
        loaderView.isHidden = true
        loaderView.alphaValue = 1
        Self.resetLayerTransform(loaderView)

        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Rewrite failed")
        iconView.contentTintColor = .systemOrange
        iconView.isHidden = false
        iconView.alphaValue = 1
        Self.resetLayerTransform(iconView)

        label.stringValue = message
        label.isHidden = message.isEmpty
    }

    /// Cross-fades the loader out and the checkmark in. Both views overlap in
    /// the same slot so nothing shifts during the transition.
    private func morphLoaderIntoCheck() {
        iconView.alphaValue = 0
        Self.resetLayerTransform(iconView)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            loaderView.animator().alphaValue = 0
            iconView.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.loaderView.stopAnimating()
            self.loaderView.isHidden = true
            self.loaderView.alphaValue = 1
        })
    }

    private func preferredSize(for mode: Mode) -> NSSize {
        switch mode {
        case .progress, .success, .hidden:
            return Self.compactSize
        case .error:
            // Let the stack size to fit the message; clamp to something sane.
            let fitting = panel?.contentView?.fittingSize ?? NSSize(width: 220, height: 36)
            return NSSize(
                width: max(Self.compactSize.width, min(fitting.width, 360)),
                height: max(Self.compactSize.height, fitting.height))
        }
    }

    // MARK: - Lifecycle / position

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.currentMode = .hidden
        })
    }

    /// Visible frame of the screen under the mouse — last-resort anchor when
    /// no focused-window rect is available.
    private static func activeScreenFrame() -> CGRect {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Pins the panel to the bottom-right corner of `anchor`, inset by a small
    /// margin. Clamped to the visible frame of the screen the anchor sits on
    /// so it can't render off-screen.
    private func position(_ panel: NSPanel, size: NSSize, near anchor: CGRect?) {
        guard let anchorRect = anchor else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let inset: CGFloat = 20
        var x = anchorRect.maxX - size.width - inset
        var y = anchorRect.minY + inset

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Layer helpers

    /// Centers a view's layer anchor point and prepares it for transform animations.
    /// Re-applies the frame after switching anchor so position doesn't drift.
    private static func prepareLayerForTransform(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            let oldFrame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.frame = oldFrame
        }
    }

    private static func resetLayerTransform(_ view: NSView) {
        prepareLayerForTransform(view)
        view.layer?.transform = CATransform3DIdentity
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Transparent root so the visual effect and overlay can be layered with
        // their own opacities. The visual effect carries the translucency; the
        // overlay (icons + label) stays at full opacity so glyphs read clearly.
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = Self.compactSize.height / 2
        bg.layer?.masksToBounds = true
        bg.alphaValue = Self.backgroundOpacity
        bg.translatesAutoresizingMaskIntoConstraints = false
        background = bg

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        iconView.isHidden = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true

        loaderView.translatesAutoresizingMaskIntoConstraints = false

        // Single slot that holds the loader and the checkmark on top of
        // each other so the morph happens in place — no stretching of the pill,
        // no side-by-side layout during the cross-fade.
        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.setContentHuggingPriority(.required, for: .horizontal)
        iconSlot.setContentHuggingPriority(.required, for: .vertical)
        iconSlot.addSubview(loaderView)
        iconSlot.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 280
        label.isHidden = true

        // The stack holds [iconSlot, label]. In compact modes the label is
        // hidden so the stack collapses to just the centered iconSlot. In
        // error mode the label appears beside the icon and the panel widens.
        let stack = NSStackView(views: [iconSlot, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(bg)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            iconSlot.widthAnchor.constraint(equalToConstant: 24),
            iconSlot.heightAnchor.constraint(equalToConstant: 24),
            loaderView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            loaderView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            loaderView.widthAnchor.constraint(equalToConstant: 24),
            loaderView.heightAnchor.constraint(equalToConstant: 24),
            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        p.contentView = root
        panel = p
        return p
    }
}

/// Tiny AI-work indicator for Writing Assistant surfaces. It stays entirely layer-backed
/// so showing it from a global hotkey remains cheap and non-activating.
final class WritingAssistantLoaderView: NSView {

    private let orbitLayer = CALayer()
    private let dotLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var didConfigureLayers = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayersIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayersIfNeeded()
    }

    func startAnimating() {
        configureLayersIfNeeded()
        layoutSubtreeIfNeeded()
        stopAnimating()

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.92
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        orbitLayer.add(rotation, forKey: "orbit.rotation")

        for (index, dot) in dotLayers.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [0.72, 1.18, 0.72]
            pulse.keyTimes = [0, 0.42, 1]
            pulse.duration = 0.72
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.13
            pulse.repeatCount = .infinity
            pulse.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            dot.add(pulse, forKey: "dot.pulse")
        }
    }

    func stopAnimating() {
        orbitLayer.removeAllAnimations()
        dotLayers.forEach { $0.removeAllAnimations() }
    }

    override func layout() {
        super.layout()
        configureLayersIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bounds = self.bounds
        orbitLayer.frame = bounds
        orbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        orbitLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let radius = min(bounds.width, bounds.height) * 0.34
        let dotSize: CGFloat = 4.2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        for (index, dot) in dotLayers.enumerated() {
            let angle = (CGFloat(index) / CGFloat(dotLayers.count)) * CGFloat.pi * 2
                - CGFloat.pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.position = point
        }

        CATransaction.commit()
    }

    private func configureLayersIfNeeded() {
        guard !didConfigureLayers else { return }

        wantsLayer = true
        guard let layer else { return }
        didConfigureLayers = true
        layer.masksToBounds = false

        orbitLayer.masksToBounds = false
        layer.addSublayer(orbitLayer)

        let colors: [NSColor] = [
            .systemCyan,
            .systemPurple,
            .systemPink
        ]

        for (index, dot) in dotLayers.enumerated() {
            dot.backgroundColor = colors[index].cgColor
            dot.shadowColor = colors[index].cgColor
            dot.shadowOpacity = 0.7
            dot.shadowRadius = 5
            dot.shadowOffset = .zero
            orbitLayer.addSublayer(dot)
        }
    }
}
