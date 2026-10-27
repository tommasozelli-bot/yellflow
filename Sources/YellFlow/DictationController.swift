import AVFoundation
import CoreGraphics
import Foundation

/// Wires the engine together. Gestures (presses of the hotkey, releases are ignored):
///   single tap        -> start recording; next tap stops it and transcribes
///   quick double tap  -> cancels the recording it just opened
final class DictationController {

    enum State {
        case idle
        case recording
        case transcribing
    }

    /// Called on the main thread — hook the menu-bar UI here.
    var onStateChange: ((State) -> Void)?
    /// Live microphone RMS level (0…1), forwarded from the recorder to drive the UI waveform.
    var onLevel: ((Float) -> Void)?
    var language: String

    private let engine: WhisperEngine
    private let recorder = AudioRecorder()
    private let hotkey: HotkeyManager
    private let transcribeQueue = DispatchQueue(label: "yellflow.transcribe", qos: .userInitiated)
    private var isRecording = false
    private var recordingStartedAt = Date.distantPast
    private var recordingStoppedAt = Date.distantPast
    private var lastPress = Date.distantPast

    /// One recording, from the tap that opens the mic to its pasted text. Its
    /// pieces and its result belong to it alone: a new take starting while this
    /// one is still transcribing can no longer throw its text away (Oct 2026:
    /// a 9-minute dictation was lost exactly like that). Touched on main only.
    private final class Take {
        let id: Int
        let historyId = UUID()
        let startedAt = Date()
        var chunkCount = 0
        var texts: [Int: String] = [:]
        /// Cancelled by a quick double tap: nothing was meant to be said.
        var discarded = false
        init(id: Int) { self.id = id }

        /// The text so far, pieces in order, cleaned and corrected.
        var text: String {
            let raw = (0..<chunkCount).compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
            // TextCleanup tidies the edges; Corrections then guarantees the spelling
            // of recurring names/jargon (proper nouns, pull request…) from corrections.txt.
            return Corrections.apply(TextCleanup.clean(raw))
        }
    }
    private var take = Take(id: 0)

    // Streaming transcription: long takes are cut at pauses while the user is
    // still talking and each piece goes to Whisper right away, so at the final
    // tap only the tail is left to transcribe.
    /// Audio captured since the last cut, not yet handed to Whisper.
    private var pending: [Float] = []
    /// The whole take, kept only to write last-recording.wav.
    private var wholeTake: [Float] = []
    /// Bumped at every new take (keys the detected language).
    private var takeId = 0
    /// Language detected for the current take (only touched on the transcribe
    /// queue). Detection is fired in the background 8 s into the recording, so
    /// it's done by the time the user taps stop; takes too short for that reuse
    /// the last detected language — Whisper's own "auto" would cost a whole
    /// extra encoder pass (+1 s) and, measured, a wrong hint doesn't hurt: the
    /// model follows the audio anyway.
    private var languageByTake: [Int: String] = [:]
    private var stickyLanguage: String?
    private var detectionEnqueued = false
    /// Seconds of speech handed to language detection.
    private let detectionSeconds = 8.0
    private var chunkTimer: Timer?
    /// After this long without running, the model's memory has probably been
    /// paged out (8 GB Macs): the next call costs +4–6 s. Warming it while the
    /// user is still talking hides that entirely.
    private let coldAfter: TimeInterval = 45

    /// Where the last dictation's audio is kept for replaying misheard words.
    static let lastRecordingURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-recording.wav")
    }()

    /// Second press within this window = double tap: cancels a take just
    /// opened, and is ignored right after a stop (it would open an empty take).
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
        recorder.onLevel = { [weak self] rms in self?.onLevel?(rms) }
    }

    func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        recorder.requestPermission(completion)
    }

    /// Runs one throwaway transcription of noise so Metal is fully initialized
    /// and the weights are resident before the user's real dictation.
    func warmUp() {
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()
            // Noise with the gate off: the VAD would (rightly) skip it as non-speech.
            var noise = [Float](repeating: 0, count: 17_600)
            for i in 0..<noise.count { noise[i] = Float.random(in: -0.02...0.02) }
            _ = autoreleasepool { self.engine.transcribeWindow(samples: noise, language: self.language, gate: false) }
            Log.write("engine warmed up in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
    }

    /// Warm-up paid WHILE the user talks: if the model has been idle long enough
    /// to be paged out, the first real call would eat the penalty at the very
    /// moment the user is waiting for text. Recent use → nothing to do.
    private func warmUpIfCold() {
        guard Date().timeIntervalSince(engine.lastUsed) > coldAfter else { return }
        Log.write("engine idle for a while — warming up during the recording")
        warmUp()
    }

    /// Installs the global hotkey. Throws if the event tap can't be created
    /// (missing Accessibility / Input Monitoring permission).
    func start() throws {
        try hotkey.start()
        Log.write("hotkey installed (Right Option, tap-to-toggle)")
    }

    func stop() {
        hotkey.stop()
        if isRecording { discardTake() }
    }

    // MARK: - Gesture dispatch

    private func handlePress() {
        let now = Date()
        guard now.timeIntervalSince(lastPress) > bounceGuard else { return }
        lastPress = now

        if isRecording {
            if now.timeIntervalSince(recordingStartedAt) < doubleTapWindow {
                // Double tap: the first press opened the mic by mistake.
                discardTake()
                onStateChange?(.idle)
                Log.write("double tap — recording cancelled")
            } else {
                finishRecording()
            }
        } else if now.timeIntervalSince(recordingStoppedAt) < doubleTapWindow {
            Log.write("press right after a stop — ignored")
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
            try recorder.start()
            isRecording = true
            recordingStartedAt = Date()
            takeId += 1
            take = Take(id: takeId)
            pending.removeAll(keepingCapacity: true)
            wholeTake.removeAll(keepingCapacity: true)
            detectionEnqueued = false
            onStateChange?(.recording)
            Log.write("recording started")
            warmUpIfCold()
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollForChunk()
            }
        } catch {
            Log.write("audio recorder failed to start: \(error)")
        }
    }

    /// Every 250 ms while recording: pull the new audio and, once enough has
    /// piled up and the user is between sentences, send that piece to Whisper.
    private func pollForChunk() {
        guard isRecording else { return }
        let fresh = recorder.take()
        pending.append(contentsOf: fresh)
        wholeTake.append(contentsOf: fresh)
        maybeDetectLanguage()
        guard let cut = AudioChunker.streamingCut(pending) else { return }
        let piece = Array(pending[..<cut])
        pending.removeFirst(cut)
        enqueueChunk(piece)
    }

    /// Once ~8 s of actual speech are in, detect the language in the background
    /// (only in Auto mode, once per take, and only within the first window).
    private func maybeDetectLanguage() {
        guard language == "auto", !detectionEnqueued, wholeTake.count <= 30 * 16_000 else { return }
        let clip = AudioChunker.fromSpeechOnset(wholeTake, seconds: detectionSeconds)
        guard Double(clip.count) / 16_000 >= detectionSeconds - 0.5 else { return }
        detectionEnqueued = true
        let take = takeId
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let lang = self.engine.detectLanguage(samples: clip)
            guard lang != "auto" else { return }
            self.languageByTake = [take: lang] // forget older takes
            self.stickyLanguage = lang
        }
    }

    private func enqueueChunk(_ piece: [Float]) {
        let take = self.take
        let index = take.chunkCount
        take.chunkCount += 1
        let seconds = Double(piece.count) / 16_000
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()
            var lang = self.language
            if lang == "auto" { lang = self.languageByTake[take.id] ?? self.stickyLanguage ?? "auto" }
            let raw = autoreleasepool {
                self.engine.transcribeWindow(samples: piece, language: lang, vocabulary: Vocabulary.prompt())
            }
            Log.write("chunk \(index + 1) (\(String(format: "%.1f", seconds))s) transcribed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \"\(raw)\"")
            DispatchQueue.main.async {
                guard !take.discarded else { return }
                take.texts[index] = raw
                // Saved while the user is still talking: whatever happens next
                // (crash, quit, focus stolen), the text is in the history.
                HistoryStore.dictations.upsert(id: take.historyId, date: take.startedAt, text: take.text)
            }
        }
    }

    private func discardTake() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        _ = recorder.stop()
        isRecording = false
        take.discarded = true // orphan any chunk still in flight
        pending.removeAll()
        wholeTake.removeAll()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingStoppedAt = Date()
        chunkTimer?.invalidate()
        chunkTimer = nil
        let tail = recorder.stop()
        pending.append(contentsOf: tail)
        wholeTake.append(contentsOf: tail)
        let total = wholeTake.count
        let seconds = Double(total) / 16_000
        Log.write("recorded \(total) samples (\(String(format: "%.1f", seconds))s), \(take.chunkCount) piece(s) already sent")

        // Nothing meaningful was said — back to idle without spinning up Whisper.
        guard total >= 6_400 else { // 0.4 s
            onStateChange?(.idle)
            return
        }
        onStateChange?(.transcribing)

        // Keep the audio so a misheard word can be replayed with new settings.
        let audio = wholeTake
        DispatchQueue.global(qos: .utility).async { WavWriter.write(samples: audio, to: Self.lastRecordingURL) }

        // The tail goes last; the serial queue then runs the join after every piece.
        enqueueChunk(pending)
        pending.removeAll(keepingCapacity: true)
        wholeTake.removeAll(keepingCapacity: true)

        // Watchdog: whatever happens, never leave the UI stuck on "transcribing".
        // Scale with the audio still to process; generous even for long tails.
        var completed = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !completed else { return }
            Log.write("⚠️ transcription watchdog fired — resetting UI to idle")
            if !self.isRecording { self.onStateChange?(.idle) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(30.0, seconds * 2.0), execute: watchdog)

        let take = self.take
        let start = Date()
        transcribeQueue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                completed = true
                watchdog.cancel()
                // A new recording may have started while we were transcribing —
                // don't yank its UI back to idle.
                if !self.isRecording { self.onStateChange?(.idle) }
                // This take's own text, even if a newer take is already recording.
                let text = take.text
                Log.write("transcribed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s after the tap: \"\(text)\"")
                guard !text.isEmpty else {
                    Log.write("empty transcript — nothing to paste")
                    return
                }
                // Save to history BEFORE pasting: inject() has no success signal, so
                // if the focus was stolen the text stays recoverable from the widget.
                HistoryStore.dictations.upsert(id: take.historyId, date: take.startedAt, text: text)
                TextInjector.inject(text)
                Log.write("pasted \(text.count) characters")
            }
        }
    }
}
