import AppKit
import QuartzCore

/// A small square floating badge near the bottom of the screen: dark, glowing
/// yellow border. Recording shows a pulsing dot + "REC"; transcribing shows just
/// a spinner. Never steals focus from the field you're typing into.
final class RecordingIndicator {

    private var panel: NSPanel?
    private let recLabel = NSTextField(labelWithString: "REC")
    private let dot = NSView()
    private let recStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let inset: CGFloat = 16
    private let badgeSize = NSSize(width: 92, height: 84)

    func showListening() { show(recording: true) }
    func showTranscribing() { show(recording: false) }

    func hide() {
        spinner.stopAnimation(nil)
        dot.layer?.removeAllAnimations()
        panel?.orderOut(nil)
    }

    private func show(recording: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel

        recStack.isHidden = !recording
        spinner.isHidden = recording
        if recording {
            spinner.stopAnimation(nil)
            pulseDot()
        } else {
            dot.layer?.removeAllAnimations()
            spinner.startAnimation(nil)
        }
        // Re-anchor on every show — the active screen may have changed.
        positionAtBottomCenter(panel)
        panel.orderFrontRegardless()
    }

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

        // Dark square badge with a glowing yellow border (glow lives in the inset margin).
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.yellFlowInk.cgColor
        badge.layer?.cornerRadius = 16
        badge.layer?.borderWidth = 2
        badge.layer?.borderColor = NSColor.yellFlow.cgColor
        badge.layer?.shadowColor = NSColor.yellFlow.cgColor
        badge.layer?.shadowRadius = 10
        badge.layer?.shadowOpacity = 0.7
        badge.layer?.shadowOffset = .zero
        badge.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.yellFlow.cgColor
        dot.layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false

        recLabel.font = .yellFlowMono(16, .heavy)
        recLabel.textColor = .yellFlow
        recLabel.alignment = .center

        recStack.orientation = .vertical
        recStack.spacing = 7
        recStack.alignment = .centerX
        recStack.translatesAutoresizingMaskIntoConstraints = false
        recStack.addArrangedSubview(dot)
        recStack.addArrangedSubview(recLabel)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        badge.addSubview(recStack)
        badge.addSubview(spinner)
        panel.contentView?.addSubview(badge)

        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                badge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                badge.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
                badge.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),

                recStack.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                recStack.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 12),
                dot.heightAnchor.constraint(equalToConstant: 12),

                spinner.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 30),
                spinner.heightAnchor.constraint(equalToConstant: 30)
            ])
        }

        positionAtBottomCenter(panel)
        return panel
    }

    private func pulseDot() {
        dot.layer?.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.2
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
    }
}
