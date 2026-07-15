import AVFoundation
import CoreGraphics
import Foundation

/// Wires the engine together. Gestures (presses of the hotkey, releases are ignored):
///   single tap        -> start recording; next tap stops it and transcribes
///   quick double tap  -> read the selected text aloud
///   any tap while the synthetic voice is speaking -> stop it
final class DictationController {

    enum State {
        case idle
        case recording
        case transcribing
    }

    /// Called on the main thread — hook the menu-bar UI here.
    var onStateChange: ((State) -> Void)?
    /// Quick double tap of the hotkey — read-aloud trigger.
    var onReadAloud: (() -> Void)?
    /// Fired right before the microphone opens (used to stop any ongoing speech
    /// so the mic doesn't transcribe our own synthetic voice).
    var onRecordingWillStart: (() -> Void)?
    /// Read-aloud state, provided by the owner: a tap while speaking only stops
    /// the voice instead of starting a recording.
    var isSpeechActive: (() -> Bool)?
    var onStopSpeech: (() -> Void)?
    var language: String

    private let engine: WhisperEngine
    private let recorder = AudioRecorder()
    private let hotkey: HotkeyManager
    private let transcribeQueue = DispatchQueue(label: "yellflow.transcribe", qos: .userInitiated)
    private var isRecording = false
    private var recordingStartedAt = Date.distantPast
    private var lastPress = Date.distantPast

    /// Second press within this window = double tap (read-aloud).
    private let doubleTapWindow: TimeInterval = 0.40
    /// A single physical press can emit repeated flagsChanged events — ignore
    /// anything faster than a human can tap twice.
    private let bounceGuard: TimeInterval = 0.12

    init(engine: WhisperEngine, language: String = "auto", hotkeyCode: CGKeyCode = 61) {
        self.engine = engine
        self.language = language
        self.hotkey = HotkeyManager(keyCode: hotkeyCode)
        // Toggle-style gestures: only key-down matters, releases are ignored.
        hotkey.onPress = { [weak self] in self?.handlePress() }
    }

    func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        recorder.requestPermission(completion)
    }

    /// Runs one throwaway transcription of silence so Metal is fully initialized
    /// before the user's first real dictation (kills first-call latency).
    func warmUp() {
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            // Low-level noise, not zeros: real silence is rejected by the energy gate.
            var noise = [Float](repeating: 0, count: 32_000)
            for i in 0..<noise.count { noise[i] = Float.random(in: -0.02...0.02) }
            _ = autoreleasepool { self.engine.transcribe(samples: noise, language: self.language) }
            Log.write("engine warmed up")
        }
    }

    /// Installs the global hotkey. Throws if the event tap can't be created
    /// (missing Accessibility / Input Monitoring permission).
    func start() throws {
        try hotkey.start()
        Log.write("hotkey installed (Right Option, tap-to-toggle)")
    }

    func stop() {
        hotkey.stop()
        if isRecording {
            _ = recorder.stop()
            isRecording = false
        }
    }

    // MARK: - Gesture dispatch

    private func handlePress() {
        let now = Date()
        guard now.timeIntervalSince(lastPress) > bounceGuard else { return }
        lastPress = now

        // Reading aloud? A tap just silences it.
        if isSpeechActive?() == true {
            onStopSpeech?()
            Log.write("press: stopped read-aloud")
            return
        }

        if isRecording {
            if now.timeIntervalSince(recordingStartedAt) < doubleTapWindow {
                // Double tap: the first press opened the mic by mistake —
                // discard it and read the selection instead.
                _ = recorder.stop()
                isRecording = false
                onStateChange?(.idle)
                Log.write("double tap — read-aloud")
                onReadAloud?()
            } else {
                finishRecording()
            }
        } else {
            beginRecording()
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.write("mic not authorized yet — prompting, skipping this press")
            recorder.requestPermission { _ in }
            return
        }
        do {
            onRecordingWillStart?()
            try recorder.start()
            isRecording = true
            recordingStartedAt = Date()
            onStateChange?(.recording)
            Log.write("recording started")
        } catch {
            Log.write("audio recorder failed to start: \(error)")
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000
        Log.write("recorded \(samples.count) samples (\(String(format: "%.1f", seconds))s)")

        // Nothing meaningful was said — back to idle without spinning up Whisper.
        guard samples.count >= 6_400 else { // 0.4 s
            onStateChange?(.idle)
            return
        }
        onStateChange?(.transcribing)

        // Watchdog: whatever happens, never leave the UI stuck on "transcribing".
        var completed = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !completed else { return }
            Log.write("⚠️ transcription watchdog fired — resetting UI to idle")
            if !self.isRecording { self.onStateChange?(.idle) }
        }
        // Scale the timeout with recording length: transcription runs several
        // times faster than real time, so this stays generous even for very
        // long dictations.
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
                // A new recording may have started while we were transcribing —
                // don't yank its UI back to idle.
                if !self.isRecording { self.onStateChange?(.idle) }
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
