import Foundation

/// Persisted settings: dictation language, speech engine and which history the widget shows.
enum Preferences {
    private static let languageKey = "yellflow.language"
    private static let historyTabKey = "yellflow.historyTab"
    private static let engineKey = "yellflow.engine"

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

    /// Parakeet by default (chosen by the user on 31/10/2026 for its speed);
    /// Whisper stays one click away in the widget.
    static var engine: EngineKind {
        get { EngineKind(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }
}
