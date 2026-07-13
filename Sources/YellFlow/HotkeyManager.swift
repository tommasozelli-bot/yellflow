import AppKit
import CoreGraphics

/// Global push-to-talk hotkey on a modifier key (default: Right Option, keycode 61),
/// implemented with a listen-only CGEventTap on flagsChanged events.
///
/// Needs the Accessibility / Input Monitoring permission — tap creation fails
/// without it, so `start()` throws and the caller can guide the user.
final class HotkeyManager {

    enum HotkeyError: Error {
        case tapCreationFailed // almost always: missing Accessibility/Input Monitoring permission
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let keyCode: CGKeyCode
    private let modifierFlag: CGEventFlags
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    /// - Parameter keyCode: a *modifier* keycode. 61 = Right Option (default),
    ///   58 = Left Option, 54/55 = Cmd, 59/62 = Ctrl, 63 = Fn/Globe.
    init(keyCode: CGKeyCode = 61) {
        self.keyCode = keyCode
        self.modifierFlag = Self.modifierFlag(for: keyCode)
    }

    func start() throws {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // C function pointer — must not capture context; `self` travels via userInfo.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                manager.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly, // never consume the key
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that are slow or when secure input kicks in — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        guard CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode else { return }

        // Press vs release: whether the key's modifier flag is present.
        // (Known corner case: holding *both* Option keys and releasing one
        // keeps the flag set — release fires when the last one goes up.)
        let pressed = event.flags.contains(modifierFlag)
        if pressed && !isDown {
            isDown = true
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !pressed && isDown {
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }

    private static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return .maskAlternate
        }
    }
}
