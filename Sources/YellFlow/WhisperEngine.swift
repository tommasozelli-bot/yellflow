import Foundation
import whisper

/// Thin, thread-safe Swift wrapper around the whisper.cpp C API.
/// Expects samples as 16 kHz mono Float32 in [-1, 1].
final class WhisperEngine {

    enum WhisperEngineError: Error {
        case modelNotFound(String)
        case modelLoadFailed(String)
    }

    private var ctx: OpaquePointer
    private let lock = NSLock()
    /// When the model last ran. The controller uses it to decide whether the
    /// weights are likely still resident (see DictationController.warmUpIfCold).
    private(set) var lastUsed = Date.distantPast

    /// 5 by default; YELLFLOW_BEAM=n overrides it for benchmarking only.
    private static let beamSize: Int32 = {
        if let raw = ProcessInfo.processInfo.environment["YELLFLOW_BEAM"], let n = Int32(raw), n >= 1 { return n }
        return 5
    }()

    /// "Core ML" when the encoder runs on the Neural Engine, "Metal" otherwise.
    private(set) var encoderBackend = "Metal"

    /// Silero voice-activity detector (~1 MB, CPU, a few ms per piece). Whisper
    /// fed with silence invents the end of a subtitle track: "Grazie.",
    /// "Grazie a tutti", "Sottotitoli a cura di…". The old energy gate let
    /// breaths and room noise through (log, Oct 2026: every bogus "Grazie" came
    /// from a 0.5–1.8 s piece with no speech in it). Pieces without speech now
    /// never reach Whisper, and the silent tail after the last word is cut off.
    /// nil if the model file is missing: the energy gate is the fallback.
    private var vad: OpaquePointer?
    private let vadLock = NSLock()
    var hasVAD: Bool { vad != nil }

    /// whisper.cpp looks for `<model>-encoder.mlmodelc` next to the model file and,
    /// when it's there, runs the encoder through Core ML (Neural Engine): measured
    /// 0.7 s per window instead of 1.5 s on Metal. The first load on a machine
    /// compiles that model (~45 s, cached afterwards). If Core ML refuses to load
    /// (Intel Mac, broken cache…), the same model is reopened through a symlink
    /// that has no encoder sibling, so the app still works on Metal.
    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperEngineError.modelNotFound(modelPath)
        }
        var cparams = whisper_context_default_params()
        // Big win for the large-v3-turbo encoder on Metal.
        cparams.flash_attn = true
        let coremlPath = (modelPath as NSString).deletingPathExtension + "-encoder.mlmodelc"
        let hasCoreML = FileManager.default.fileExists(atPath: coremlPath)
        if let context = whisper_init_from_file_with_params(modelPath, cparams) {
            ctx = context
            encoderBackend = hasCoreML ? "Core ML" : "Metal"
            loadVAD(near: modelPath)
            return
        }
        guard hasCoreML else { throw WhisperEngineError.modelLoadFailed(modelPath) }
        Log.write("Core ML encoder failed to load — falling back to Metal")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("whisper-model-metal.bin")
        try? FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: modelPath))
        guard let context = whisper_init_from_file_with_params(alias.path, cparams) else {
            throw WhisperEngineError.modelLoadFailed(modelPath)
        }
        ctx = context
        encoderBackend = "Metal"
        loadVAD(near: modelPath)
    }

    deinit {
        whisper_free(ctx)
        if let vad { whisper_vad_free(vad) }
    }

    /// The bundle ships it as whisper-vad.bin next to the model; the self-test
    /// points at the download cache, where it keeps its original name.
    private func loadVAD(near modelPath: String) {
        let dir = (modelPath as NSString).deletingLastPathComponent
        let candidates = ["whisper-vad.bin", "ggml-silero-v5.1.2.bin"].map { (dir as NSString).appendingPathComponent($0) }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            Log.write("⚠️ VAD model not found — falling back to the energy gate")
            return
        }
        var params = whisper_vad_default_context_params()
        params.n_threads = 2
        params.use_gpu = false
        vad = whisper_vad_init_from_file_with_params(path, params)
        Log.write(vad == nil ? "⚠️ VAD model failed to load" : "VAD loaded (Silero)")
    }

    /// Where the speech is, in samples. nil = VAD unavailable (caller decides);
    /// an empty array = no speech at all.
    func speechSegments(_ samples: [Float]) -> [Range<Int>]? {
        guard let vad else { return nil }
        vadLock.lock()
        defer { vadLock.unlock() }
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

    /// - Parameters:
    ///   - language: "auto", "it" or "en". Anything else falls back to "auto".
    ///   - vocabulary: optional comma-separated custom terms (names, jargon) used
    ///     to bias decoding via Whisper's initial prompt. Never appears verbatim
    ///     in the output — it only nudges token probabilities.
    /// - Returns: the transcript, or "" on failure / silence / too-short input.
    ///
    /// Audio longer than one Whisper window is cut at pauses (AudioChunker) and
    /// transcribed piece by piece, so nothing is chopped at the 30 s marks.
    func transcribe(samples: [Float], language: String, vocabulary: String? = nil) -> String {
        let pieces = AudioChunker.split(samples)
        let lang = language == "auto" ? detectLanguage(samples: pieces[0]) : language
        if pieces.count == 1 {
            return transcribeWindow(samples: samples, language: lang, vocabulary: vocabulary)
        }
        return pieces
            .map { transcribeWindow(samples: $0, language: lang, vocabulary: vocabulary) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cheap language detection, ~⅓ of a full encoder pass.
    ///
    /// Whisper's built-in "auto" costs a WHOLE extra encoder pass on every call
    /// (measured: 2.5 s vs 1.5 s on a 3 s clip). Here the encoder only looks at
    /// the first ~10 s of speech (audio_ctx 500 of 1500), which is plenty to
    /// tell Italian from English. Returns "auto" when it can't tell, so the
    /// caller falls back to Whisper's own detection.
    func detectLanguage(samples: [Float]) -> String {
        let clip = AudioChunker.fromSpeechOnset(samples, seconds: 10)
        guard clip.count >= 16_000 else { return "auto" } // < 1 s of speech: not worth it
        var pcm = clip
        let minSamples = 17_600
        if pcm.count < minSamples { pcm.append(contentsOf: [Float](repeating: 0, count: minSamples - pcm.count)) }

        lock.lock()
        defer { lock.unlock(); lastUsed = Date() }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let cLang = strdup("auto")
        defer { free(cLang) }
        params.language = UnsafePointer(cLang)
        params.detect_language = true
        params.audio_ctx = 500
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        let result = pcm.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else { return "auto" }
        let id = whisper_full_lang_id(ctx)
        guard id >= 0, let cstr = whisper_lang_str(id) else { return "auto" }
        let lang = String(cString: cstr)
        Log.write("language detected: \(lang)")
        return lang
    }

    /// One piece of audio that fits in a single 30 s window.
    /// - Parameter gate: false only for the warm-up, which feeds noise on purpose.
    func transcribeWindow(samples input: [Float], language: String, vocabulary: String? = nil, gate: Bool = true) -> String {
        // Ignore accidental taps (< 0.3 s of audio).
        guard input.count >= 4_800 else { return "" }
        var samples = input
        var speechSeconds = Double(input.count) / 16_000

        if gate, let segments = speechSegments(input) {
            speechSeconds = Double(segments.reduce(0) { $0 + $1.count }) / 16_000
            guard let first = segments.first, let last = segments.last, speechSeconds >= 0.25 else {
                Log.write("no speech in \(String(format: "%.1f", Double(input.count) / 16_000))s piece — skipped")
                return ""
            }
            // Keep a little air around the words; drop the long silences at the
            // edges, which is where Whisper makes things up.
            let lo = max(0, first.lowerBound - 4_800)   // 0.3 s
            let hi = min(input.count, last.upperBound + 6_400) // 0.4 s
            samples = Array(input[lo..<hi])
        } else if gate {
            // No VAD model: energy gate. Typical speech RMS is 0.02–0.1; ambient
            // room noise sits well below 0.002.
            var sumSquares: Float = 0
            for s in input { sumSquares += s * s }
            guard (sumSquares / Float(input.count)).squareRoot() > 0.0015 else { return "" }
        }

        // whisper_full rejects inputs shorter than ~1 s — pad with silence.
        var pcm = samples
        let minSamples = 17_600 // 1.1 s @ 16 kHz
        if pcm.count < minSamples {
            pcm.append(contentsOf: [Float](repeating: 0, count: minSamples - pcm.count))
        }

        let lang = (language == "auto" || whisper_lang_id(language) >= 0) ? language : "auto"

        // Serialize access — one whisper context is not re-entrant.
        lock.lock()
        defer { lock.unlock(); lastUsed = Date() }

        // Beam search explores several hypotheses in parallel instead of committing
        // to the single most likely token — noticeably fewer misheard words than greedy.
        // NOTE: do not be tempted by params.audio_ctx to speed up short clips —
        // with beam search + carry_initial_prompt it makes the decoder loop and
        // repeat itself, and the fallback retries end up SLOWER than the full
        // 30 s window. Verified empirically.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = Self.beamSize
        // Keep the C strings alive for the whole whisper_full call, free afterwards.
        let cLang = strdup(lang)
        defer { free(cLang) }
        params.language = UnsafePointer(cLang)
        var cPrompt: UnsafeMutablePointer<CChar>?
        if let vocabulary, !vocabulary.isEmpty {
            cPrompt = strdup(vocabulary)
            params.initial_prompt = UnsafePointer(cPrompt)
            // no_context resets the prompt between 30 s windows; this keeps the
            // vocabulary bias applied to every window regardless.
            params.carry_initial_prompt = true
        }
        defer { if let cPrompt { free(cPrompt) } }
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        // Never emit "[Musica]", "♪" and friends — they are hallucinations on
        // breaths and keyboard noise, not speech.
        params.suppress_nst = true
        // Each dictation is independent: do NOT carry the previous transcription's
        // tokens over as a prompt (that made Whisper "remember" and repeat earlier
        // text, especially when switching language between takes).
        params.no_context = true

        let result = pcm.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segment)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if gate, speechSeconds < 1.0, Self.isPhantom(text) {
            Log.write("dropped phantom \"\(text)\" (\(String(format: "%.1f", speechSeconds))s of speech)")
            return ""
        }
        return text
    }
}
