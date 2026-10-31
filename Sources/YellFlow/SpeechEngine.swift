import Foundation
import whisper

/// What the controller needs from a speech-to-text model. Two implementations:
/// WhisperEngine (large-v3-turbo, takes the vocabulary as a prompt) and
/// ParakeetEngine (Parakeet Ultra through transcribe.cpp, ~10x faster, no prompt).
/// Expects samples as 16 kHz mono Float32 in [-1, 1].
protocol SpeechEngine: AnyObject {
    /// Shown in the log and in the widget.
    var name: String { get }
    /// When the model last ran (see DictationController.warmUpIfCold).
    var lastUsed: Date { get }
    /// "auto", "it" or "en"; "auto" when the engine can't tell or doesn't need to.
    func detectLanguage(samples: [Float]) -> String
    /// One piece of audio. gate: false only for the warm-up, which feeds noise.
    func transcribeWindow(samples: [Float], language: String, vocabulary: String?, gate: Bool) -> String
    /// A whole recording of any length (self-test).
    func transcribe(samples: [Float], language: String, vocabulary: String?) -> String
}

extension SpeechEngine {
    func transcribeWindow(samples: [Float], language: String, vocabulary: String? = nil) -> String {
        transcribeWindow(samples: samples, language: language, vocabulary: vocabulary, gate: true)
    }
}

/// Which engine the user picked in the widget.
enum EngineKind: String {
    case whisper, parakeet
}

/// Silero voice-activity detector (~1 MB, CPU, a few ms per piece), shared by
/// both engines. Whisper fed with silence invents the end of a subtitle track:
/// "Grazie.", "Grazie a tutti", "Sottotitoli a cura di…". The old energy gate
/// let breaths and room noise through (log, Oct 2026: every bogus "Grazie" came
/// from a 0.5–1.8 s piece with no speech in it). Pieces without speech now never
/// reach the model, and the silent tail after the last word is cut off.
/// It lives in whisper.framework but needs no Whisper model, so the Parakeet
/// engine uses it without loading Whisper's 800 MB.
final class VoiceDetector {
    private let vad: OpaquePointer
    private let lock = NSLock()

    /// The bundle ships it as whisper-vad.bin; the self-test points at the
    /// download cache, where it keeps its original name. nil if missing: the
    /// energy gate is the fallback.
    static func load(near path: String) -> VoiceDetector? {
        let dir = (path as NSString).deletingLastPathComponent
        let candidates = ["whisper-vad.bin", "ggml-silero-v5.1.2.bin"].map { (dir as NSString).appendingPathComponent($0) }
            + [Bundle.main.url(forResource: "whisper-vad", withExtension: "bin")?.path].compactMap { $0 }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            Log.write("⚠️ VAD model not found — falling back to the energy gate")
            return nil
        }
        var params = whisper_vad_default_context_params()
        params.n_threads = 2
        params.use_gpu = false
        guard let vad = whisper_vad_init_from_file_with_params(file, params) else {
            Log.write("⚠️ VAD model failed to load")
            return nil
        }
        Log.write("VAD loaded (Silero)")
        return VoiceDetector(vad: vad)
    }

    private init(vad: OpaquePointer) { self.vad = vad }

    deinit { whisper_vad_free(vad) }

    /// Where the speech is, in samples. nil = the detector failed (caller
    /// decides); an empty array = no speech at all.
    func speechSegments(_ samples: [Float]) -> [Range<Int>]? {
        lock.lock()
        defer { lock.unlock() }
        var params = whisper_vad_default_params()
        params.threshold = 0.5
        params.min_speech_duration_ms = 200
        params.min_silence_duration_ms = 300
        params.speech_pad_ms = 0 // padding is added by the caller, in samples
        guard let segs = samples.withUnsafeBufferPointer({ buf in
            whisper_vad_segments_from_samples(vad, params, buf.baseAddress, Int32(buf.count))
        }) else { return nil }
        defer { whisper_vad_free_segments(segs) }
        var out: [Range<Int>] = []
        for i in 0..<whisper_vad_segments_n_segments(segs) {
            // whisper.cpp reports VAD times in centiseconds.
            let a = Int(whisper_vad_segments_get_segment_t0(segs, i) * 160)
            let b = Int(whisper_vad_segments_get_segment_t1(segs, i) * 160)
            let lo = max(0, min(a, samples.count)), hi = max(lo, min(b, samples.count))
            if hi > lo { out.append(lo..<hi) }
        }
        return out
    }
}

/// The checks every piece goes through before and after the model, the same
/// for both engines.
enum SpeechGate {

    /// The piece with its silent edges trimmed and how much speech it holds,
    /// or nil when there is nothing worth transcribing.
    static func prepare(_ input: [Float], detector: VoiceDetector?, gate: Bool) -> (samples: [Float], speechSeconds: Double)? {
        // Ignore accidental taps (< 0.3 s of audio).
        guard input.count >= 4_800 else { return nil }
        let seconds = Double(input.count) / 16_000
        guard gate else { return (input, seconds) }

        if let detector, let segments = detector.speechSegments(input) {
            let speech = Double(segments.reduce(0) { $0 + $1.count }) / 16_000
            guard let first = segments.first, let last = segments.last, speech >= 0.25 else {
                Log.write("no speech in \(String(format: "%.1f", seconds))s piece — skipped")
                return nil
            }
            // Keep a little air around the words; drop the long silences at the
            // edges, which is where the models make things up.
            let lo = max(0, first.lowerBound - 4_800)   // 0.3 s
            let hi = min(input.count, last.upperBound + 6_400) // 0.4 s
            return (Array(input[lo..<hi]), speech)
        }
        // No VAD model: energy gate. Typical speech RMS is 0.02–0.1; ambient
        // room noise sits well below 0.002.
        var sumSquares: Float = 0
        for s in input { sumSquares += s * s }
        guard (sumSquares / Float(input.count)).squareRoot() > 0.0015 else { return nil }
        return (input, seconds)
    }

    /// What Whisper writes when it hears nothing (subtitle-track endings it
    /// was trained on). Dropped only when the VAD heard under a second of
    /// "speech" (a breath, a click) and the whole piece is that phrase alone,
    /// so a "grazie" inside a sentence is never touched.
    private static let phantomPhrases: Set<String> = [
        "grazie", "grazie a tutti", "grazie mille", "grazie per l'attenzione",
        "grazie per la visione", "grazie per aver guardato",
        "sottotitoli creati dalla comunità amara.org", "sottotitoli e revisione a cura di qtss",
        "sottotitoli a cura di qtss", "thank you", "thank you.", "thanks for watching",
        "thank you for watching", "you",
    ]

    static func isPhantom(_ text: String) -> Bool {
        let norm = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?…\"'«»-—").union(.whitespacesAndNewlines))
            .replacingOccurrences(of: "  ", with: " ")
        return norm.isEmpty || phantomPhrases.contains(norm)
    }

    /// The last check on a model's output.
    static func finish(_ text: String, speechSeconds: Double, gate: Bool) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if gate, speechSeconds < 1.0, isPhantom(text) {
            Log.write("dropped phantom \"\(text)\" (\(String(format: "%.1f", speechSeconds))s of speech)")
            return ""
        }
        return text
    }
}
