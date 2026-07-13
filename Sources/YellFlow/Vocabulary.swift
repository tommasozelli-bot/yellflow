import Foundation

/// User-editable custom vocabulary that biases Whisper towards names and jargon
/// it would otherwise mishear (brands, people, technical terms, mixed-language
/// words like "deploy" or "backend" inside an Italian sentence).
///
/// Lives OUTSIDE the app and outside the repository, in
/// ~/Library/Application Support/YellFlow/vocabulary.txt — personal words never
/// end up in the codebase. One term per line, `#` starts a comment. The file is
/// re-read automatically when it changes; no restart needed.
enum Vocabulary {

    private static let maxPromptLength = 800 // keep the bias prompt small and fast

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    static var path: String { fileURL.path }

    private static let starterTemplate = """
    # Yell Flow — custom vocabulary / vocabolario personale
    #
    # One word or phrase per line. These terms bias the transcription so that
    # names and jargon come out spelled right (brands, people, products,
    # technical terms, English words you use inside Italian sentences).
    #
    # Una parola o frase per riga. Questi termini orientano la trascrizione:
    # nomi propri, brand, termini tecnici, parole inglesi usate nell'italiano.
    #
    # Examples / esempi:
    # deploy
    # backend
    # pull request

    """

    private static var cached: (prompt: String, modified: Date)?
    private static let lock = NSLock()

    /// The comma-separated prompt built from the file, or nil when empty.
    /// Creates a commented starter file on first use.
    static func prompt() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? starterTemplate.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.write("vocabulary: created starter file at \(fileURL.path)")
        }

        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached, cached.modified == modified {
            return cached.prompt.isEmpty ? nil : cached.prompt
        }

        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let terms = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var prompt = terms.joined(separator: ", ")
        if prompt.count > maxPromptLength {
            prompt = String(prompt.prefix(maxPromptLength))
            Log.write("vocabulary: trimmed to \(maxPromptLength) chars — consider shortening the file")
        }
        cached = (prompt, modified)
        if !prompt.isEmpty { Log.write("vocabulary: \(terms.count) terms loaded") }
        return prompt.isEmpty ? nil : prompt
    }
}
