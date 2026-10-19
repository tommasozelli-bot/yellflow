import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Inserts text at the current cursor position in whatever app has focus:
/// puts it on the clipboard, presses ⌘V, then gives the user's clipboard back.
///
/// History: 2.0/2.1 typed the text with synthetic Unicode key events (20
/// characters every 1.5 ms) to stay off the clipboard. Terminals, VS Code and
/// Electron apps drop part of input that fast, so long dictations arrived with
/// only their last piece, or nothing (Oct 2026). Pasting is one event, which is
/// what VoiceInk, Wispr Flow and every other dictation app do.
///
/// The clipboard race that pushed 2.0 away from pasting (the target app read
/// the clipboard after it had already been restored, and pasted stale text)
/// is avoided by restoring late (1.5 s) and only if nobody has written to the
/// clipboard in the meantime.
///
/// Requires the Accessibility permission (posting synthetic key events).
enum TextInjector {

    /// Marks our temporary clipboard content so clipboard managers (Raycast,
    /// Paste, Maccy…) don't record every dictation. See nspasteboard.org.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let restoreDelay: TimeInterval = 1.5

    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Must be called on the main thread.
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        pressCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // The user copied something in the meantime: theirs wins.
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Deep copy of every item and every type on the clipboard (text, images,
    /// files, rich text), so it can be put back exactly as it was.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { original in
            let copy = NSPasteboardItem()
            var any = false
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                    any = true
                }
            }
            return any ? copy : nil
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        // Explicit flags: ⌘ only, whatever modifier the hotkey left behind.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
