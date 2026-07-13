import Foundation

/// Light, non-destructive cleanup of raw Whisper output.
/// Whisper already punctuates; we just tidy the edges.
enum TextCleanup {

    // Standalone filler words (EN + IT), removed only as whole words.
    private static let fillers = ["uh", "uhh", "um", "umm", "uhm", "erm", "eh", "ehm", "mm", "mmm"]

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Drop Whisper's non-speech annotations that show up on short/noisy clips,
        // e.g. [Musica], [Music], [BLANK_AUDIO], (applausi), ♪ … ♪.
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "♪", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // If nothing but punctuation/symbols is left, there was no real speech.
        if text.range(of: "\\p{L}|\\p{N}", options: .regularExpression) == nil { return "" }

        for filler in fillers {
            text = text.replacingOccurrences(
                of: "\\b\(filler)\\b[ ,]*",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Collapse runs of whitespace.
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize the first letter.
        if let first = text.first {
            text = String(first).uppercased() + text.dropFirst()
        }
        return text
    }
}
