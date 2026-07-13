import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Checks the three permissions Yell Flow needs and opens the right
/// System Settings pane for each.
enum PermissionsHelper {

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// True only when everything needed for the hotkey + paste is granted.
    static var allGranted: Bool {
        hasAccessibility && hasMicrophone && hasInputMonitoring
    }

    static func openAccessibilitySettings() {
        open("com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("com.apple.preference.security?Privacy_Microphone")
    }

    static func openInputMonitoringSettings() {
        open("com.apple.preference.security?Privacy_ListenEvent")
    }

    /// Opens the first pane that still needs attention.
    static func openFirstMissingSettings() {
        if !hasAccessibility { openAccessibilitySettings() }
        else if !hasInputMonitoring { openInputMonitoringSettings() }
        else if !hasMicrophone { openMicrophoneSettings() }
    }

    private static func open(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }
}
