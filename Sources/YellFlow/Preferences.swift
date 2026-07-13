import Foundation

/// Persisted settings: dictation language and read-aloud voice gender.
enum Preferences {
    private static let languageKey = "yellflow.language"
    private static let voiceGenderKey = "yellflow.voiceGender"

    /// "auto", "it" or "en". Defaults to "auto" — Whisper detects the language
    /// from the audio itself.
    static var language: String {
        get {
            let value = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
            return (value == "auto" || value == "it" || value == "en") ? value : "auto"
        }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    /// "f" (female, default) or "m" (male) — voice used by read-aloud.
    static var voiceGender: String {
        get {
            let value = UserDefaults.standard.string(forKey: voiceGenderKey) ?? "f"
            return (value == "f" || value == "m") ? value : "f"
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceGenderKey) }
    }
}
