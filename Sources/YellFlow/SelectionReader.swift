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
            return text
        }
        return viaCopy()
    }

    // MARK: - Accessibility route

    private static func viaAccessibility() -> String? {
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

        // Let the physical Right-Option release fully settle first: if ⌥ is still
        // down at HID level, our ⌘C arrives as ⌥⌘C — a *different* shortcut in
        // some apps (VS Code!) and the copy never happens.
        usleep(150_000)

        let before = pasteboard.changeCount

        // Snapshot the clipboard so we can put it back.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        sendCmdC()

        // Wait for the copy to land (max ~700 ms — Electron apps like VS Code
        // route the clipboard through their renderer and can be slow).
        var text: String?
        for _ in 0..<28 {
            usleep(25_000)
            if pasteboard.changeCount != before {
                usleep(30_000) // let all representations finish landing
                text = pasteboard.string(forType: .string)
                break
            }
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
        up.post(tap: .cgSessionEventTap)
    }
}
