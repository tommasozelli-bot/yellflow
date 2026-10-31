import Foundation

/// User-editable custom vocabulary that biases Whisper towards names and jargon
/// it would otherwise mishear (brands, people, technical terms, mixed-language
/// words like "deploy" or "backend" inside an Italian sentence).
///
/// Lives OUTSIDE the app and outside the repository, in
/// ~/Library/Application Support/YellFlow/vocabulary.txt — personal words never
/// end up in the codebase. One term per line, `#` starts a comment. The file is
/// re-read automatically when it changes; no restart needed.
///
/// This is only a SOFT phonetic bias and it must stay short: whisper.cpp keeps
/// just ~224 tokens of the initial prompt and silently drops the rest. Guaranteed
/// spelling fixes for recurring names now live in Corrections.txt (unlimited,
/// deterministic) — keep this file to a handful of tricky-to-spell terms.
enum Vocabulary {

    // whisper.cpp only keeps ~224 tokens of the prompt; aim well under that.
    // Rough estimate: ~1 token per ~4 characters, so ~800 chars ≈ ~200 tokens.
    private static let maxPromptTokens = 200
    private static let charsPerToken = 4
    private static let maxPromptLength = maxPromptTokens * charsPerToken // ~800 chars

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

    private static var cached: (prompt: String, all: [String], modified: Date)?
    private static let lock = NSLock()

    /// Below this heading the terms are for Parakeet only: Whisper's prompt is
    /// full, while Parakeet's SoundAlike pass has no size limit.
    private static func isParakeetHeading(_ line: String) -> Bool {
        line.hasPrefix("## ") && line.lowercased().contains("parakeet")
    }

    /// The comma-separated prompt built from the file, or nil when empty.
    /// Creates a commented starter file on first use.
    static func prompt() -> String? {
        let prompt = load().prompt
        return prompt.isEmpty ? nil : prompt
    }

    /// Every term in the file, Parakeet section included, plus the names on the
    /// right of corrections.txt (canonical spellings, already curated): the
    /// list SoundAlike matches Parakeet's output against.
    static func allTerms() -> [String] {
        load().all + Corrections.canonicalTerms()
    }

    private static func load() -> (prompt: String, all: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? starterTemplate.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.write("vocabulary: created starter file at \(fileURL.path)")
        }

        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached, cached.modified == modified {
            return (cached.prompt, cached.all)
        }

        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var terms: [String] = [], all: [String] = []
        var parakeetOnly = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isParakeetHeading(trimmed) { parakeetOnly = true; continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            all.append(trimmed)
            if !parakeetOnly { terms.append(trimmed) }
        }

        // Keep the earliest terms and drop trailing ones that won't fit in the
        // ~224-token prompt window (estimated at maxPromptLength chars). Dropping
        // whole terms is cleaner than a mid-word character cut.
        var kept: [String] = []
        var length = 0
        for term in terms {
            let added = kept.isEmpty ? term.count : term.count + 2 // ", "
            if length + added > maxPromptLength { break }
            kept.append(term)
            length += added
        }
        if kept.count < terms.count {
            let dropped = terms.count - kept.count
            Log.write("vocabulary: \(dropped) term(s) don't fit the ~\(maxPromptTokens)-token prompt and were dropped — move guaranteed fixes to corrections.txt")
        }
        let prompt = kept.joined(separator: ", ")
        cached = (prompt, all, modified)
        if !all.isEmpty { Log.write("vocabulary: \(terms.count) terms for Whisper, \(all.count) for Parakeet") }
        return (prompt, all)
    }
}
