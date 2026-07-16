import AppKit

extension NSColor {
    /// Yell Flow primary accent — #FFD400.
    static let yellFlow = NSColor(srgbRed: 1.0, green: 0.831, blue: 0.0, alpha: 1.0)
    /// Dark card background (near-black, matching the Gemini look).
    static let yellFlowInk = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0)
    /// Primary light text on the dark card.
    static let yellFlowText = NSColor(white: 0.90, alpha: 1.0)
    /// Dim secondary text.
    static let yellFlowDim = NSColor(white: 0.55, alpha: 1.0)
    /// Hairline separators on the dark card.
    static let yellFlowHair = NSColor(white: 1.0, alpha: 0.12)
}

extension NSFont {
    /// Monospaced display font used for the title and the REC badge.
    static func yellFlowMono(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Layout + animation tokens for the floating recording indicator, so nothing
/// visual is hardcoded at the call site.
enum YellFlowLayout {
    /// Wide, low pill (Wispr-style) that hosts the live waveform.
    static let pillSize = NSSize(width: 220, height: 48)
    /// Glow margin around the pill (the shadow bleeds into this inset).
    static let pillInset: CGFloat = 16
    /// Number of vertical bars drawn in the waveform.
    static let waveformBars = 24
    /// Bar width and inter-bar gap, in points.
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarGap: CGFloat = 4
    /// Bar height clamps as a fraction of the pill's usable height.
    static let waveformIdleHeight: CGFloat = 0.14
    static let waveformMaxHeight: CGFloat = 0.86
    /// Smoothing factor per frame for bar heights (0 = frozen, 1 = instant).
    static let waveformSmoothing: CGFloat = 0.35
    /// How hard the RMS is boosted before clamping (voice RMS is small).
    static let waveformGain: Float = 6.0
    /// Cross-fade duration for the recording <-> transcribing transition.
    static let stateFade: TimeInterval = 0.25
    /// Dot/bar pulse cadence.
    static let pulseDuration: TimeInterval = 0.6
}

extension NSColor {
    /// Waveform bar color — the primary accent.
    static var yellFlowBar: NSColor { .yellFlow }
}
