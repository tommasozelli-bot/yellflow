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

    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperEngineError.modelNotFound(modelPath)
        }
        var cparams = whisper_context_default_params()
        // Big win for the large-v3-turbo encoder on Metal.
        cparams.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperEngineError.modelLoadFailed(modelPath)
        }
        ctx = context
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
    func transcribe(samples: [Float], language: String, vocabulary: String? = nil) -> String {
        // Ignore accidental taps (< 0.3 s of audio).
        guard samples.count >= 4_800 else { return "" }

        // whisper_full rejects inputs shorter than ~1 s — pad with silence.
        var pcm = samples
        let minSamples = 17_600 // 1.1 s @ 16 kHz
        if pcm.count < minSamples {
            pcm.append(contentsOf: [Float](repeating: 0, count: minSamples - pcm.count))
        }

        let validLanguages: Set<String> = ["auto", "it", "en"]
        let lang = validLanguages.contains(language) ? language : "auto"

        // Serialize access — one whisper context is not re-entrant.
        lock.lock()
        defer { lock.unlock() }

        // Beam search explores several hypotheses in parallel instead of committing
        // to the single most likely token — noticeably fewer misheard words than greedy.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
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
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
