import AppKit
import QuartzCore

final class WaveformView: NSView {

    enum Mode {
        case idle
        case recording
        case transcribing
    }

    private(set) var mode: Mode = .idle
    private var levels: [Float] = []
    private var systemLevels: [Float] = []
    private let maxSamples = 140
    /// Smoothed envelope used to shape the recording waveform — keeps motion fluid.
    private var envelope: Float = 0
    private var systemEnvelope: Float = 0
    /// Phase used to drive the transcribing animation.
    private var animationPhase: CGFloat = 0
    private var animationTimer: Timer?

    /// Semi-transparent olive green used to overlay the system-audio waveform
    /// while system-audio transcription is active.
    private static let systemAudioColor = NSColor(red: 0.50, green: 0.55, blue: 0.18, alpha: 0.55)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        seedIdleLevels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Public API

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .idle:
            stopAnimation()
            seedIdleLevels()
        case .recording:
            stopAnimation()
            levels.removeAll()
            systemLevels.removeAll()
            envelope = 0
            systemEnvelope = 0
            // Start a slow heartbeat so the waveform is animated even before
            // audio arrives. Bars are mostly driven by audio data updates; the
            // timer just keeps the subtle wiggle moving.
            startAnimation(fps: 12)
        case .transcribing:
            // The soft "thinking" wave does not need display-rate redraws.
            startAnimation(fps: 16)
        }
        needsDisplay = true
    }

    // Note: these update the level buffers but intentionally do NOT set
    // `needsDisplay = true`. The animation timer is the sole redraw clock —
    // audio arrives at ~12 buffers/sec which would otherwise force redraws on
    // top of the timer's. The eye only sees the timer cadence anyway.

    func appendLevel(_ rawLevel: Float) {
        guard mode == .recording else { return }
        // Speech RMS sits around 0.01–0.1 linear. Compress the dynamic range with a
        // power curve so quiet syllables become clearly visible.
        let amplified = min(1, max(0, powf(rawLevel * 6.5, 0.55)))
        // Smooth toward the new level so bars don't pop discontinuously.
        envelope = envelope * 0.55 + amplified * 0.45
        let display = min(1, envelope * 1.15)
        levels.append(display)
        if levels.count > maxSamples {
            levels.removeFirst(levels.count - maxSamples)
        }
    }

    func appendSystemLevel(_ rawLevel: Float) {
        guard mode == .recording else { return }
        let amplified = min(1, max(0, powf(rawLevel * 6.5, 0.55)))
        systemEnvelope = systemEnvelope * 0.55 + amplified * 0.45
        let display = min(1, systemEnvelope * 1.15)
        systemLevels.append(display)
        if systemLevels.count > maxSamples {
            systemLevels.removeFirst(systemLevels.count - maxSamples)
        }
    }

    func reset() {
        levels.removeAll()
        systemLevels.removeAll()
        envelope = 0
        systemEnvelope = 0
        animationPhase = 0
        seedIdleLevels()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(bounds)

        switch mode {
        case .idle:
            drawDottedLine(in: context, bounds: bounds)
        case .recording:
            drawRecordingBars(in: context, bounds: bounds)
        case .transcribing:
            drawTranscribingWave(in: context, bounds: bounds)
        }
    }

    // MARK: - Idle (dotted line, matches the reference design)

    private func seedIdleLevels() {
        levels = (0..<maxSamples).map { _ in 0 }
    }

    private func drawDottedLine(in context: CGContext, bounds: CGRect) {
        let dotSize: CGFloat = 2
        let gap: CGFloat = 4
        let step = dotSize + gap
        let centerY = bounds.midY
        let startX = bounds.minX + 12
        let endX = bounds.maxX - 12
        var x = startX
        context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        while x <= endX {
            let rect = CGRect(x: x, y: centerY - dotSize / 2, width: dotSize, height: dotSize)
            context.fillEllipse(in: rect)
            x += step
        }
    }

    // MARK: - Recording (live bars)

    private func drawRecordingBars(in context: CGContext, bounds: CGRect) {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1.6
        let step = barWidth + gap
        let maxVisible = max(0, Int(bounds.width / step) - 4)

        let micVisibleCount = min(levels.count, maxVisible)
        let sysVisibleCount = min(systemLevels.count, maxVisible)

        guard micVisibleCount > 0 || sysVisibleCount > 0 else {
            drawDottedLine(in: context, bounds: bounds)
            return
        }

        // Draw system bars first so the white mic bars sit on top of the olive
        // green overlay. Both layers share the same horizontal layout.
        if sysVisibleCount > 0 {
            drawBars(
                in: context,
                bounds: bounds,
                samples: systemLevels,
                visibleCount: sysVisibleCount,
                barWidth: barWidth,
                step: step,
                color: Self.systemAudioColor,
                useIntensityAlpha: false
            )
        }

        if micVisibleCount > 0 {
            drawBars(
                in: context,
                bounds: bounds,
                samples: levels,
                visibleCount: micVisibleCount,
                barWidth: barWidth,
                step: step,
                color: .white,
                useIntensityAlpha: true
            )
        }
    }

    private func drawBars(
        in context: CGContext,
        bounds: CGRect,
        samples: [Float],
        visibleCount: Int,
        barWidth: CGFloat,
        step: CGFloat,
        color: NSColor,
        useIntensityAlpha: Bool
    ) {
        let centerY = bounds.midY
        let maxBarHeight = bounds.height * 0.9
        let minBarHeight: CGFloat = 2

        let startIndex = max(0, samples.count - visibleCount)
        let totalWidth = CGFloat(visibleCount) * step
        let baseStartX = bounds.midX - totalWidth / 2

        let baseAlpha = color.alphaComponent

        for i in 0..<visibleCount {
            let level = samples[startIndex + i]
            // A subtle phase wiggle so even silent stretches don't look frozen.
            let wiggle = 0.04 + 0.03 * sin(animationPhase * 1.2 + CGFloat(i) * 0.12)
            let combined = max(CGFloat(level), wiggle)
            let barHeight = max(minBarHeight, combined * maxBarHeight)
            let x = baseStartX + CGFloat(i) * step

            // Fade older bars slightly toward the leading edge for a tail effect.
            let recencyAlpha: CGFloat = 0.35 + 0.65 * (CGFloat(i) / CGFloat(max(visibleCount - 1, 1)))
            let intensityAlpha: CGFloat = useIntensityAlpha ? (0.4 + 0.6 * combined) : 1
            let alpha = min(1, baseAlpha * recencyAlpha * intensityAlpha)

            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            // 2 px wide bars — the rounded corners are imperceptible here, so
            // fill plain rects to avoid per-bar CGPath allocation.
            let rect = CGRect(
                x: x,
                y: centerY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            context.fill(rect)
        }
    }

    // MARK: - Transcribing (flowing animated wave)

    private func drawTranscribingWave(in context: CGContext, bounds: CGRect) {
        let centerY = bounds.midY
        let amplitude = bounds.height * 0.32
        let startX = bounds.minX + 16
        let endX = bounds.maxX - 16
        let dotSize: CGFloat = 2.5
        let gap: CGFloat = 3.5
        let step = dotSize + gap
        let count = max(1, Int((endX - startX) / step))

        // Three travelling sine waves with different speeds and frequencies create a soft
        // "thinking" motion. Combined amplitude is normalized to keep it within bounds.
        for i in 0..<count {
            let x = startX + CGFloat(i) * step
            let progress = CGFloat(i) / CGFloat(count)

            let s1 = sin(progress * 6.0 + animationPhase * 2.4)
            let s2 = sin(progress * 11.0 - animationPhase * 1.6)
            let s3 = sin(progress * 3.5 + animationPhase * 3.2)
            let y = centerY + (s1 * 0.55 + s2 * 0.3 + s3 * 0.4) * amplitude / 1.25

            // Highlight a moving "pulse" along the dots so the eye follows it.
            let pulseCenter = (sin(animationPhase * 0.9) + 1) / 2  // 0…1
            let distanceFromPulse = abs(progress - pulseCenter)
            let pulseGlow = max(0, 1 - distanceFromPulse * 4) // sharp falloff
            let baseAlpha: CGFloat = 0.45
            let alpha = min(1, baseAlpha + 0.55 * pulseGlow)

            context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            let rect = CGRect(x: x, y: y - dotSize / 2, width: dotSize, height: dotSize)
            context.fillEllipse(in: rect)
        }
    }

    // MARK: - Animation

    private func startAnimation(fps: Double) {
        stopAnimation()
        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationPhase += CGFloat(1.0 / fps) * 2.0  // ~2 rad/s
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
