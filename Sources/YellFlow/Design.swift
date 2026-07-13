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
