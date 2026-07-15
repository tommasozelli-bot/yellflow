import AppKit
import ApplicationServices
import CoreGraphics

/// Grabs the currently selected text in whatever app has focus.
///
/// Strategy:
/// 1. Accessibility API (`kAXSelectedTextAttribute` of the focused element) —
///    instant and clipboard-free; works in most native apps.
/// 2. Fallback: synthesize ⌘C, wait for the pasteboard to actually change
///    (polling `changeCount`), read the string, then restore the user's
///    original clipboard. Reading is under our control here, so there is no
///    paste-timing race like the one that plagued injection.
enum SelectionReader {

    static func selectedText() -> String? {
        if let text = viaAccessibility(), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Log.write("selection: via accessibility (\(text.count) chars)")
            return text
        }
        let copied = viaCopy()
        Log.write(copied != nil
                  ? "selection: via ⌘C fallback (\(copied!.count) chars)"
                  : "selection: both accessibility and ⌘C came back empty")
        return copied
    }

    // MARK: - Accessibility route

    private static func viaAccessibility() -> String? {
        // Electron apps (VS Code!) keep their accessibility tree disabled until
        // someone asks for it — setting AXManualAccessibility on the frontmost
        // app turns it on, and with it kAXSelectedText starts answering.
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String else { return nil }
        return text
    }

    // MARK: - ⌘C fallback

    private static func viaCopy() -> String? {
        let pasteboard = NSPasteboard.general

        // Wait for the physical Right-Option to actually be released: with the
        // double-tap gesture the second press is still down when we get here,
        // and a lingering ⌥ turns our ⌘C into ⌥⌘C — a *different* shortcut in
        // some apps (VS Code!) and the copy never happens.
        for _ in 0..<40 where CGEventSource.keyState(.combinedSessionState, key: 61) {
            usleep(25_000)
        }
        usleep(100_000)

        let before = pasteboard.changeCount

        // Snapshot the clipboard so we can put it back.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        // Two attempts: Electron apps occasionally swallow the first synthetic
        // ⌘C while their renderer is busy.
        var text: String?
        attempts: for attempt in 0..<2 {
            sendCmdC()
            // Wait for the copy to land (max ~700 ms — Electron apps like VS
            // Code route the clipboard through their renderer and can be slow).
            for _ in 0..<28 {
                usleep(25_000)
                if pasteboard.changeCount != before {
                    usleep(30_000) // let all representations finish landing
                    text = pasteboard.string(forType: .string)
                    break attempts
                }
            }
            if attempt == 0 { Log.write("selection: first ⌘C ignored, retrying") }
        }

        // Restore the user's clipboard only if our ⌘C actually replaced it.
        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? text : nil
    }

    private static func sendCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // 'c'
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Session tap: modifier flags are taken as-is, not merged with lingering
        // hardware modifier state (more reliable for Electron apps).
        down.post(tap: .cgSessionEventTap)
        usleep(20_000) // some renderers drop a zero-length keypress
        up.post(tap: .cgSessionEventTap)
    }
}
