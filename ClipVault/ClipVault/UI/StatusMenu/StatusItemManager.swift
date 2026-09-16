import AppKit

final class StatusItemManager: NSObject {

    enum ClickAction: Equatable {
        case toggleSearchPanel
        case showMenu
    }

    private static let iconScale: CGFloat = 0.93
    private static let iconHorizontalPadding: CGFloat = 0
    private static let rewriteAnimationFrameRate: TimeInterval = 1.0 / 24.0

    private var statusItem: NSStatusItem?

    /// The menu-bar button, used as the anchor for the meeting prompt bubble.
    var statusButton: NSStatusBarButton? { statusItem?.button }

    private let menuBuilder = StatusMenuBuilder()
    private var menu: NSMenu?
    private var appearanceObservation: NSKeyValueObservation?
    private var rewriteAnimationTimer: Timer?
    private var rewriteAnimationFrame = 0

    /// Current recorder state — drives both the icon badge and menu item enable state.
    private(set) var recorderState: ActivityCaptureState = .idle

    /// Voice recording state — drives the mic glyph and conditional menu items.
    private(set) var voiceRecordingActive: Bool = false
    private(set) var voicePanelVisible: Bool = false

    /// AI rewrite state — temporarily replaces the menu bar icon with an animated loader.
    private(set) var writingRewriteActive: Bool = false

    deinit {
        stopRewriteAnimation()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Re-render the composited icon when the menu bar switches between
            // light and dark so the manually-tinted base stays readable.
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.updateIcon()
            }
        }
        updateIcon()
        refreshMenu()
    }

    /// Update both the menu and icon to reflect a new recorder state.
    func updateRecorderState(_ state: ActivityCaptureState) {
        recorderState = state
        refreshMenu()
        updateIcon()
    }

    /// Update menu/icon to reflect voice recording state.
    func updateVoiceRecordingState(active: Bool, panelVisible: Bool) {
        voiceRecordingActive = active
        voicePanelVisible = panelVisible
        refreshMenu()
        updateIcon()
    }

    /// Update menu/icon to reflect focused-text AI rewrite progress.
    func updateWritingRewriteState(active: Bool) {
        guard writingRewriteActive != active else { return }
        writingRewriteActive = active
        if active {
            startRewriteAnimation()
        } else {
            stopRewriteAnimation()
        }
        updateIcon()
    }

    /// Rebuild the menu, retaining the current recorder state.
    /// Called from Preferences when launch-at-login state or AI key changes.
    func refreshMenu() {
        menu = menuBuilder.buildMenu(
            recorderState: recorderState,
            voiceRecordingActive: voiceRecordingActive,
            voicePanelVisible: voicePanelVisible
        )
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        switch Self.clickAction(for: NSApp.currentEvent) {
        case .showMenu:
            showMenu()
        case .toggleSearchPanel:
            (NSApp.delegate as? AppDelegate)?.openSearchPanel()
        }
    }

    static func clickAction(for event: NSEvent?) -> ClickAction {
        guard let event else { return .toggleSearchPanel }

        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return .showMenu
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control) ? .showMenu : .toggleSearchPanel
        default:
            return .toggleSearchPanel
        }
    }

    private func showMenu() {
        guard let statusItem, let menu else { return }
        statusItem.popUpMenu(menu)
    }

    // MARK: - Icon badge

    /// Update the menu bar button image.
    ///
    /// When idle, the asset catalog icon is used as a template so macOS tints it
    /// to match the menu bar. When recording activity or audio, the base shape is
    /// drawn manually in `labelColor` (resolved under the button's effective
    /// appearance, so it follows light/dark) and a small semi-transparent badge
    /// is overlaid: green for activity, red for voice. The composited icon is
    /// no longer a template, but `labelColor` keeps it readable in either mode.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if writingRewriteActive {
            let image = Self.rewriteLoaderImage(
                frame: rewriteAnimationFrame,
                appearance: button.effectiveAppearance
            )
            button.image = image
            statusItem?.length = image.size.width + Self.iconHorizontalPadding * 2
            return
        }

        let activityBadge: NSColor?
        switch recorderState {
        case .idle: activityBadge = nil
        case .recording: activityBadge = NSColor.systemGreen.withAlphaComponent(0.65)
        case .paused: activityBadge = NSColor.systemYellow.withAlphaComponent(0.65)
        }
        let voiceBadge: NSColor? = voiceRecordingActive
            ? NSColor.systemRed.withAlphaComponent(0.65)
            : nil

        let image: NSImage?
        if activityBadge == nil && voiceBadge == nil {
            image = Self.makeMenuBarImage()
        } else {
            image = Self.composedIcon(
                activityBadge: activityBadge,
                voiceBadge: voiceBadge,
                appearance: button.effectiveAppearance
            )
        }
        button.image = image
        if let image {
            statusItem?.length = image.size.width + Self.iconHorizontalPadding * 2
        }
    }

    private func startRewriteAnimation() {
        rewriteAnimationTimer?.invalidate()
        rewriteAnimationFrame = 0
        let timer = Timer(timeInterval: Self.rewriteAnimationFrameRate, repeats: true) {
            [weak self] _ in
            guard let self, self.writingRewriteActive else { return }
            self.rewriteAnimationFrame = (self.rewriteAnimationFrame + 1) % 96
            self.updateIcon()
        }
        rewriteAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRewriteAnimation() {
        rewriteAnimationTimer?.invalidate()
        rewriteAnimationTimer = nil
        rewriteAnimationFrame = 0
    }

    /// Build a template-rendered, 7% downscaled copy of the asset catalog icon.
    /// Mutating the shared `NSImage(named:)` instance would affect every consumer,
    /// so we copy first and resize the copy's `size` (the bitmap reps stay shared).
    private static func makeMenuBarImage() -> NSImage? {
        guard let original = NSImage(named: "MenuBarIcon"),
              let copy = original.copy() as? NSImage
        else { return nil }
        copy.size = NSSize(
            width: (original.size.width * iconScale).rounded(),
            height: (original.size.height * iconScale).rounded()
        )
        copy.isTemplate = true
        return copy
    }

    /// Compose the menu bar icon with optional activity/voice badges.
    /// The base is drawn in `labelColor` resolved under `appearance` so it stays
    /// readable in both light and dark menu bars without becoming raw black.
    private static func composedIcon(
        activityBadge: NSColor?,
        voiceBadge: NSColor?,
        appearance: NSAppearance
    ) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = NSSize(
            width: (base.size.width * iconScale).rounded(),
            height: (base.size.height * iconScale).rounded()
        )
        let result = NSImage(size: size, flipped: false) { rect in
            // Tint the base shape in labelColor under the menu bar's appearance.
            appearance.performAsCurrentDrawingAppearance {
                NSColor.labelColor.set()
                rect.fill()
            }
            base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)

            let r: CGFloat = 3.0
            if let color = activityBadge {
                let badgeRect = CGRect(
                    x: rect.maxX - r * 2 - 1,
                    y: rect.maxY - r * 2 - 1,
                    width: r * 2,
                    height: r * 2
                )
                color.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            if let color = voiceBadge {
                let badgeRect = CGRect(
                    x: rect.minX + 1,
                    y: rect.minY + 1,
                    width: r * 2,
                    height: r * 2
                )
                color.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            return true
        }
        result.isTemplate = false
        return result
    }

    /// Draw a compact frame of the same orbit/halo rewrite loader used by the HUD.
    private static func rewriteLoaderImage(frame: Int, appearance: NSAppearance) -> NSImage {
        let size = menuBarIconSize()
        let result = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = min(rect.width, rect.height) * 0.32
                let haloRect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                let pulse = (sin(CGFloat(frame) * 0.32) + 1) / 2
                let haloAlpha = 0.28 + pulse * 0.24
                let halo = NSBezierPath(ovalIn: haloRect)
                halo.lineWidth = 1.35
                NSColor.controlAccentColor.withAlphaComponent(haloAlpha).setStroke()
                halo.stroke()

                let colors: [NSColor] = [
                    .systemCyan,
                    .systemPurple,
                    .systemPink
                ]
                let dotSize: CGFloat = 3.4
                let baseAngle = CGFloat(frame) * 0.26 - CGFloat.pi / 2
                for index in 0..<colors.count {
                    let phase = CGFloat(index) / CGFloat(colors.count) * CGFloat.pi * 2
                    let angle = baseAngle + phase
                    let scale = 0.78 + 0.28 * ((sin(CGFloat(frame) * 0.4 + phase) + 1) / 2)
                    let diameter = dotSize * scale
                    let dotCenter = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                    let dotRect = CGRect(
                        x: dotCenter.x - diameter / 2,
                        y: dotCenter.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    colors[index].withAlphaComponent(0.92).setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                }
            }
            return true
        }
        result.isTemplate = false
        return result
    }

    private static func menuBarIconSize() -> NSSize {
        if let base = NSImage(named: "MenuBarIcon") {
            return NSSize(
                width: (base.size.width * iconScale).rounded(),
                height: (base.size.height * iconScale).rounded()
            )
        }
        return NSSize(width: 18, height: 18)
    }
}
