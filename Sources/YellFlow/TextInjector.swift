import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Inserts text at the current cursor position in whatever app has focus, by
/// synthesizing Unicode keyboard input.
///
/// This deliberately does NOT go through the clipboard. The old clipboard-based
/// approach (copy → ⌘V → restore) had a race: if the target app read the
/// clipboard slightly after we had already restored it, it pasted the user's
/// *previous* clipboard contents (stale text) instead of the transcription.
/// Typing the characters directly removes the clipboard from the equation
/// entirely — and leaves the user's clipboard untouched.
///
/// Requires the Accessibility permission (posting synthetic key events).
enum TextInjector {

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Must be called on the main thread.
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)

        // Post in small chunks so fast synthetic input isn't dropped by the target app.
        let chunkSize = 20
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            let chunk = Array(units[index..<end])
            chunk.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                    up.post(tap: .cghidEventTap)
                }
            }
            usleep(1_500) // ~1.5 ms between chunks
            index = end
        }
    }
}
