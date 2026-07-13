import AVFoundation
import CoreGraphics
import Foundation

/// Wires the engine together:
/// hotkey press  -> start recording
/// hotkey release -> stop, transcribe off the main thread, paste on the main thread.
final class DictationController {

    enum State {
        case idle
        case recording
        case transcribing
    }

    /// Called on the main thread — hook the menu-bar UI here.
    var onStateChange: ((State) -> Void)?
    /// A quick tap of the hotkey (too short to be a dictation) — read-aloud trigger.
    var onTap: (() -> Void)?
    /// Fired right before the microphone opens (used to stop any ongoing speech
    /// so the mic doesn't transcribe our own synthetic voice).
    var onRecordingWillStart: (() -> Void)?
    var language: String

    private let engine: WhisperEngine
    private let recorder = AudioRecorder()
    private let hotkey: HotkeyManager
    private let transcribeQueue = DispatchQueue(label: "yellflow.transcribe", qos: .userInitiated)
    private var isRecording = false
    private var lastEnd = Date.distantPast

    init(engine: WhisperEngine, language: String = "auto", hotkeyCode: CGKeyCode = 61) {
        self.engine = engine
        self.language = language
        self.hotkey = HotkeyManager(keyCode: hotkeyCode)
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
    }

    func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        recorder.requestPermission(completion)
    }

    /// Runs one throwaway transcription of silence so Metal is fully initialized
    /// before the user's first real dictation (kills first-call latency).
    func warmUp() {
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let silence = [Float](repeating: 0, count: 16_000)
            _ = autoreleasepool { self.engine.transcribe(samples: silence, language: self.language) }
            Log.write("engine warmed up")
        }
    }

    /// Installs the global hotkey. Throws if the event tap can't be created
    /// (missing Accessibility / Input Monitoring permission).
    func start() throws {
        try hotkey.start()
        Log.write("hotkey installed (Right Option)")
    }

    func stop() {
        hotkey.stop()
        if isRecording {
            _ = recorder.stop()
            isRecording = false
        }
    }

    // MARK: - Push-to-talk flow

    private func beginRecording() {
        guard !isRecording else { return } // ignore overlapping presses
        // Debounce: a single physical tap of Right Option can emit repeated
        // flagsChanged events — ignore a new start right after one just ended.
        guard Date().timeIntervalSince(lastEnd) > 0.3 else {
            Log.write("debounced spurious hotkey press")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.write("mic not authorized yet — prompting, skipping this press")
            recorder.requestPermission { _ in }
            return
        }
        do {
            onRecordingWillStart?()
            try recorder.start()
            isRecording = true
            onStateChange?(.recording)
            Log.write("recording started")
        } catch {
            Log.write("audio recorder failed to start: \(error)")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        lastEnd = Date()
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000
        Log.write("recorded \(samples.count) samples (\(String(format: "%.1f", seconds))s)")

        // Too short to be dictation -> it was a TAP: the read-aloud gesture.
        guard samples.count >= 6_400 else { // 0.4 s
            Log.write("tap gesture (\(samples.count) samples) — read-aloud")
            onStateChange?(.idle)
            onTap?()
            return
        }
        onStateChange?(.transcribing)

        // Watchdog: whatever happens, never leave the UI stuck on "transcribing".
        var completed = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !completed else { return }
            Log.write("⚠️ transcription watchdog fired — resetting UI to idle")
            self.onStateChange?(.idle)
        }
        // Scale the timeout with recording length: transcription runs ~10x faster
        // than real time, so this stays generous even for very long dictations.
        let watchdogTimeout = max(30.0, seconds * 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeout, execute: watchdog)

        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()
            let raw = autoreleasepool {
                self.engine.transcribe(samples: samples, language: self.language, vocabulary: Vocabulary.prompt())
            }
            let text = TextCleanup.clean(raw)
            Log.write("transcribed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \"\(text)\"")
            DispatchQueue.main.async {
                completed = true
                watchdog.cancel()
                self.onStateChange?(.idle)
                guard !text.isEmpty else {
                    Log.write("empty transcript — nothing to paste")
                    return
                }
                TextInjector.inject(text)
                Log.write("pasted \(text.count) characters")
            }
        }
    }
}
