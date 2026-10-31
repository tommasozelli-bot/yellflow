import Foundation
import whisper

/// Thin, thread-safe Swift wrapper around the whisper.cpp C API.
/// Expects samples as 16 kHz mono Float32 in [-1, 1].
final class WhisperEngine: SpeechEngine {

    let name = "Whisper"

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

    /// Silero, shared with the gate (see VoiceDetector). nil = energy gate.
    private var detector: VoiceDetector?
    var hasVAD: Bool { detector != nil }

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
            detector = VoiceDetector.load(near: modelPath)
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
        detector = VoiceDetector.load(near: modelPath)
    }

    deinit {
        whisper_free(ctx)
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
    func transcribe(samples: [Float], language: String, vocabulary: String?) -> String {
        let pieces = AudioChunker.split(samples)
        let lang = language == "auto" ? detectLanguage(samples: pieces[0]) : language
        if pieces.count == 1 {
            return transcribeWindow(samples: samples, language: lang, vocabulary: vocabulary, gate: true)
        }
        return pieces
            .map { transcribeWindow(samples: $0, language: lang, vocabulary: vocabulary, gate: true) }
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
    func transcribeWindow(samples input: [Float], language: String, vocabulary: String?, gate: Bool) -> String {
        guard let prepared = SpeechGate.prepare(input, detector: detector, gate: gate) else { return "" }
        let samples = prepared.samples, speechSeconds = prepared.speechSeconds

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
        return SpeechGate.finish(text, speechSeconds: speechSeconds, gate: gate)
    }
}
