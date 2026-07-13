import AVFoundation
import Foundation
import NaturalLanguage

/// On-device text-to-speech. Detects whether the text is Italian or English and
/// picks a voice of the preferred gender for that language. No cloud, no extra
/// permissions.
final class SpeechEngine: NSObject, AVSpeechSynthesizerDelegate {

    /// Called on the main thread with `true` when speech starts, `false` when it
    /// finishes or is cancelled.
    var onStateChange: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// - Parameter fallbackLanguage: "it" or "en" — used only when detection is
    ///   inconclusive (e.g. a URL or a string of numbers).
    func speak(_ text: String, fallbackLanguage: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        let language = Self.detectLanguage(trimmed) ?? (fallbackLanguage == "it" ? "it-IT" : "en-US")
        let voice = Self.pickVoice(language: language, gender: Preferences.voiceGender)
        Log.write("speak: \(trimmed.count) chars, lang=\(language), voice=\(voice?.name ?? "system default")")

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Language & voice selection

    /// "it-IT" / "en-US", or nil when the recognizer can't tell.
    private static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.italian, .english]
        recognizer.processString(String(text.prefix(400)))
        switch recognizer.dominantLanguage {
        case .italian: return "it-IT"
        case .english: return "en-US"
        default: return nil
        }
    }

    /// Best installed voice for the language matching the wanted gender
    /// ("m"/"f"); falls back to any voice of that language.
    private static func pickVoice(language: String, gender: String) -> AVSpeechSynthesisVoice? {
        let wanted: AVSpeechSynthesisVoiceGender = (gender == "m") ? .male : .female
        let forLanguage = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        let byGender = forLanguage.filter { $0.gender == wanted }
        let pool = byGender.isEmpty ? forLanguage : byGender
        // Prefer enhanced/premium voices when installed.
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onStateChange?(true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onStateChange?(false) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onStateChange?(false) }
    }
}
