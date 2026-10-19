import AppKit
import QuartzCore

/// A wide, low floating pill near the bottom of the screen: dark, glowing
/// yellow border. Recording shows a live audio waveform; transcribing shows a
/// spinner. Never steals focus from the field you're typing into.
final class RecordingIndicator {

    private var panel: NSPanel?
    private let waveform = WaveformView()
    private let spinner = NSProgressIndicator()
    private let inset = YellFlowLayout.pillInset
    private let badgeSize = YellFlowLayout.pillSize

    // MARK: - Public API (called by AppDelegate)

    func showListening() { show(recording: true) }
    func showTranscribing() { show(recording: false) }

    /// Feeds a fresh RMS level (0…1) into the live waveform.
    func updateLevel(_ rms: Float) { waveform.push(rms) }

    func hide() {
        spinner.stopAnimation(nil)
        waveform.stop()
        panel?.orderOut(nil)
    }

    // MARK: - State

    private func show(recording: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel

        if recording {
            spinner.stopAnimation(nil)
            waveform.start()
            crossfade(showWaveform: true)
        } else {
            waveform.stop()
            spinner.startAnimation(nil)
            crossfade(showWaveform: false)
        }
        // Re-anchor on every show — the active screen may have changed.
        positionAtBottomCenter(panel)
        panel.orderFrontRegardless()
    }

    /// Soft cross-fade between the waveform and the spinner instead of an
    /// instant isHidden swap.
    private func crossfade(showWaveform: Bool) {
        waveform.isHidden = false
        spinner.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = YellFlowLayout.stateFade
            waveform.animator().alphaValue = showWaveform ? 1 : 0
            spinner.animator().alphaValue = showWaveform ? 0 : 1
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.waveform.isHidden = !showWaveform
            self.spinner.isHidden = showWaveform
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panelSize = NSSize(width: badgeSize.width + inset * 2, height: badgeSize.height + inset * 2)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .statusBar level + .fullScreenAuxiliary: stay visible above regular
        // windows AND above full-screen apps (VS Code full screen hid the badge
        // at the old .floating level).
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Dark pill with a glowing yellow border (glow lives in the inset margin).
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.yellFlowInk.cgColor
        badge.layer?.cornerRadius = badgeSize.height / 2   // true pill
        badge.layer?.borderWidth = 2
        badge.layer?.borderColor = NSColor.yellFlow.cgColor
        badge.layer?.shadowColor = NSColor.yellFlow.cgColor
        badge.layer?.shadowRadius = 10
        badge.layer?.shadowOpacity = 0.7
        badge.layer?.shadowOffset = .zero
        badge.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.alphaValue = 0
        spinner.translatesAutoresizingMaskIntoConstraints = false

        badge.addSubview(waveform)
        badge.addSubview(spinner)
        panel.contentView?.addSubview(badge)

        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                badge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                badge.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
                badge.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),

                waveform.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 18),
                waveform.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -18),
                waveform.topAnchor.constraint(equalTo: badge.topAnchor),
                waveform.bottomAnchor.constraint(equalTo: badge.bottomAnchor),

                spinner.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 26),
                spinner.heightAnchor.constraint(equalToConstant: 26)
            ])
        }

        positionAtBottomCenter(panel)
        return panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
    }
}

/// Live audio waveform: N vertical yellow bars driven by a circular buffer of
/// recent RMS levels. `push(_:)` slides in the newest level on the right; a
/// ~60 Hz timer eases the drawn heights toward their targets so the motion is
/// smooth even though levels arrive only ~15x/s. With no input the bars settle
/// back to a low "idle" height.
final class WaveformView: NSView {

    private let barCount = YellFlowLayout.waveformBars
    private let idle = YellFlowLayout.waveformIdleHeight
    private let maxH = YellFlowLayout.waveformMaxHeight

    // Normalized (0…1) heights: `targets` is the circular buffer, `current` is
    // the eased value actually drawn.
    private var targets: [CGFloat]
    private var current: [CGFloat]
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        targets = Array(repeating: idle, count: barCount)
        current = Array(repeating: idle, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { false }

    // MARK: - Drive

    /// Starts the smoothing/redraw loop.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the loop and relaxes the bars back to idle.
    func stop() {
        timer?.invalidate()
        timer = nil
        for i in 0..<barCount { targets[i] = idle; current[i] = idle }
        needsDisplay = true
    }

    /// Pushes a fresh RMS level (0…1) as the newest (right-most) bar.
    ///
    /// Mapped in decibels, not linearly: a voice on the MacBook mic sits at
    /// RMS 0.01–0.05, which the old linear ×6 gain turned into bars 6–30%
    /// tall, so the pill looked frozen while you talked (Oct 2026).
    func push(_ level: Float) {
        let db = 20 * log10(max(level, 1e-6))
        let lo = YellFlowLayout.waveformFloorDB, hi = YellFlowLayout.waveformCeilDB
        let loud = CGFloat(min(max((db - lo) / (hi - lo), 0), 1))
        // A little per-bar variation so speech reads as a wave, not a block.
        let norm = idle + loud * (maxH - idle) * CGFloat.random(in: 0.75...1.0)
        targets.removeFirst()
        targets.append(norm)
        if timer == nil { start() }   // tolerate levels arriving before start()
    }

    private var phase: CGFloat = 0

    /// One animation frame: ease each bar toward its target, then redraw.
    /// In silence the bars keep breathing in a slow travelling wave, so it is
    /// always clear the mic is open.
    private func tick() {
        let s = YellFlowLayout.waveformSmoothing
        phase += 0.08
        for i in 0..<barCount {
            let breath = idle + YellFlowLayout.waveformBreath * (1 + sin(phase - CGFloat(i) * 0.45)) / 2
            let goal = max(targets[i], breath)
            current[i] += (goal - current[i]) * s
            // Bars drift back to idle when no fresh levels arrive.
            targets[i] += (idle - targets[i]) * 0.06
        }
        needsDisplay = true
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let w = YellFlowLayout.waveformBarWidth
        let gap = YellFlowLayout.waveformBarGap
        let totalW = CGFloat(barCount) * w + CGFloat(barCount - 1) * gap
        let startX = (bounds.width - totalW) / 2
        let midY = bounds.height / 2
        let usable = bounds.height * 0.9

        NSColor.yellFlowBar.setFill()
        for i in 0..<barCount {
            let h = max(current[i] * usable, w)   // never thinner than a dot
            let x = startX + CGFloat(i) * (w + gap)
            let rect = NSRect(x: x, y: midY - h / 2, width: w, height: h)
            NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
