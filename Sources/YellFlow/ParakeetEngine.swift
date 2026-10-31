import CTranscribe
import Foundation

/// Parakeet Ultra (NVIDIA Parakeet TDT 0.6B v3 refined by Moondream, 25 European
/// languages) through transcribe.cpp, the engine behind Handy. Measured on the
/// user's own dictations (31/10/2026, M3 8 GB, Metal): 15 s of audio in 0.24 s,
/// 77 s in 1.8 s, model loaded in 0.9 s, ~220 MB resident — against Whisper's
/// 1.2–4.8 s per piece, up to 24 s to wake up, ~800 MB. It takes no vocabulary
/// prompt, so the user's names are applied afterwards (SoundAlike), and it
/// writes its own punctuation.
final class ParakeetEngine: SpeechEngine {

    enum ParakeetError: Error {
        case modelNotFound(String)
        case modelLoadFailed(String, String)
    }

    let name = "Parakeet"
    private(set) var lastUsed = Date.distantPast
    /// "MTL0" on Metal, "CPU" otherwise.
    private(set) var backend = ""

    private var session: OpaquePointer?
    private let modelPath: String
    private let detector: VoiceDetector?
    private let lock = NSLock()

    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ParakeetError.modelNotFound(modelPath)
        }
        self.modelPath = modelPath
        detector = VoiceDetector.load(near: modelPath)
        try open(onCPU: false)
    }

    deinit {
        if let session { transcribe_session_free(session) }
    }

    private func open(onCPU: Bool) throws {
        if let session { transcribe_session_free(session) }
        session = nil
        var load = transcribe_model_load_params()
        transcribe_model_load_params_init(&load)
        if onCPU { load.backend = TRANSCRIBE_BACKEND_CPU }
        var params = transcribe_session_params()
        transcribe_session_params_init(&params)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        var opened: OpaquePointer?
        let status = transcribe_open(modelPath, &load, &params, &opened)
        guard status == TRANSCRIBE_OK, let opened else {
            throw ParakeetError.modelLoadFailed(modelPath, String(cString: transcribe_status_string(Int32(status.rawValue))))
        }
        session = opened
        backend = transcribe_model_backend(transcribe_get_model(opened)).map { String(cString: $0) } ?? "?"
    }

    /// Parakeet recognises the language of every piece by itself, at no cost.
    func detectLanguage(samples: [Float]) -> String { "auto" }

    func transcribe(samples: [Float], language: String, vocabulary: String?) -> String {
        // Long audio is chunked inside transcribe.cpp; no 30 s window to respect.
        transcribeWindow(samples: samples, language: language, vocabulary: vocabulary, gate: true)
    }

    /// `vocabulary` is ignored: the terms come from Vocabulary.allTerms().
    func transcribeWindow(samples input: [Float], language: String, vocabulary: String?, gate: Bool) -> String {
        guard let prepared = SpeechGate.prepare(input, detector: detector, gate: gate) else { return "" }
        var pcm = prepared.samples
        if pcm.count < 17_600 { // 1.1 s, like Whisper: very short inputs get padded
            pcm.append(contentsOf: [Float](repeating: 0, count: 17_600 - pcm.count))
        }

        lock.lock()
        defer { lock.unlock(); lastUsed = Date() }

        guard var words = run(pcm, language: language) else { return "" }
        if words.isEmpty, let session, let text = transcribe_full_text(session) {
            words = String(cString: text).split(separator: " ").map { SoundAlike.Word(text: String($0), confidence: 1) }
        }
        let text = gate ? SoundAlike.apply(words, terms: Vocabulary.allTerms()) : words.map(\.text).joined(separator: " ")
        return SpeechGate.finish(text, speechSeconds: prepared.speechSeconds, gate: gate)
    }

    /// Words with their lowest token probability, or nil on failure. A Metal
    /// failure is recoverable in-process (transcribe.h): reopen on CPU, retry once.
    /// Caller holds `lock`.
    private func run(_ pcm: [Float], language: String) -> [SoundAlike.Word]? {
        var status = runOnce(pcm, language: language)
        if status == TRANSCRIBE_ERR_BACKEND {
            Log.write("⚠️ Parakeet: Metal failed — reopening on CPU")
            do { try open(onCPU: true) } catch { Log.write("⚠️ Parakeet: \(error)"); return nil }
            status = runOnce(pcm, language: language)
        }
        guard status == TRANSCRIBE_OK, let session else {
            Log.write("⚠️ Parakeet run failed: \(String(cString: transcribe_status_string(Int32(status.rawValue))))")
            return nil
        }

        var words: [SoundAlike.Word] = []
        for i in 0..<transcribe_n_words(session) {
            var word = transcribe_word()
            transcribe_word_init(&word)
            guard transcribe_get_word(session, i, &word) == TRANSCRIBE_OK, let cText = word.text else { continue }
            var confidence: Float = 1
            for t in word.first_token..<(word.first_token + word.n_tokens) {
                var token = transcribe_token()
                transcribe_token_init(&token)
                if transcribe_get_token(session, t, &token) == TRANSCRIBE_OK, !token.p.isNaN {
                    confidence = min(confidence, token.p)
                }
            }
            let text = String(cString: cText).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { words.append(SoundAlike.Word(text: text, confidence: confidence)) }
        }
        return words
    }

    private func runOnce(_ pcm: [Float], language: String) -> transcribe_status {
        guard let session else { return TRANSCRIBE_ERR_BACKEND }
        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        params.timestamps = TRANSCRIBE_TIMESTAMPS_TOKEN // per-token probabilities for SoundAlike
        let cLang = (language == "it" || language == "en") ? strdup(language) : nil
        defer { free(cLang) }
        params.language = UnsafePointer(cLang)
        return pcm.withUnsafeBufferPointer { buf in
            transcribe_run(session, buf.baseAddress, Int32(buf.count), &params)
        }
    }
}
