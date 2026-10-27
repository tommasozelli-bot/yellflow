import Foundation

/// Persisted settings: dictation language and which history the widget shows.
enum Preferences {
    private static let languageKey = "yellflow.language"
    private static let historyTabKey = "yellflow.historyTab"

    /// "auto", "it" or "en". Defaults to "auto" — Whisper detects the language
    /// from the audio itself.
    static var language: String {
        get {
            let value = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
            return (value == "auto" || value == "it" || value == "en") ? value : "auto"
        }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    /// "dictated" (default) or "copied": the history tab open in the widget.
    static var historyTab: String {
        get { UserDefaults.standard.string(forKey: historyTabKey) == "copied" ? "copied" : "dictated" }
        set { UserDefaults.standard.set(newValue, forKey: historyTabKey) }
    }
}
