import Foundation

/// Deterministic post-transcription fixes applied AFTER Whisper returns text.
///
/// Whisper's custom vocabulary (see Vocabulary.swift) is only a soft phonetic
/// bias, and whisper.cpp silently truncates the prompt to ~224 tokens — so a long
/// list of names is partly discarded. This layer is the guaranteed one: plain
/// whole-word find/replace rules with no size limit, independent of the model.
///
/// Lives OUTSIDE the app and the repository, in
/// ~/Library/Application Support/YellFlow/corrections.txt — personal fixes never
/// end up in the codebase. One rule per line, `wrong => right`, `#` starts a
/// comment. The file is re-read automatically when it changes; no restart needed.
enum Corrections {

    private static let separator = " => "

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("corrections.txt")
    }()

    static var path: String { fileURL.path }

    private static let starterTemplate = """
    # Yell Flow — deterministic corrections / correzioni deterministiche
    #
    # One rule per line: wrong => right
    # Every whole-word, case-insensitive match of "wrong" is replaced with
    # "right" exactly as written here. Lines starting with # are comments.
    #
    # Una regola per riga: sbagliato => giusto
    # Ogni occorrenza intera e senza distinzione di maiuscole di "sbagliato"
    # viene sostituita con "giusto" così come è scritto qui. Le righe che
    # iniziano con # sono commenti.
    #
    # Examples / esempi:
    # git hub => GitHub
    # push a request => pull request
    # javascript => JavaScript

    """

    private static var cached: (rules: [(wrong: String, right: String)], modified: Date)?
    private static let lock = NSLock()

    /// Applies every rule in file order to `text` and returns the corrected string.
    /// Creates a commented starter file on first use. Safe to call from a
    /// background thread.
    static func apply(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let rules = loadRules()
        guard !rules.isEmpty else { return text }

        var result = text
        for rule in rules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.wrong)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            // Escape $ and \ so the replacement is used literally, not as a template.
            let template = rule.right
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// Reads and parses the rules, re-reading only when the file's mtime changes.
    /// Caller must hold `lock`.
    private static func loadRules() -> [(wrong: String, right: String)] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? starterTemplate.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.write("corrections: created starter file at \(fileURL.path)")
        }

        let modified = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached, cached.modified == modified {
            return cached.rules
        }

        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var rules: [(wrong: String, right: String)] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let sep = trimmed.range(of: separator) else { continue }
            let wrong = String(trimmed[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(trimmed[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            if wrong.isEmpty { continue }
            rules.append((wrong, right))
        }

        cached = (rules, modified)
        if !rules.isEmpty { Log.write("corrections: \(rules.count) rules loaded") }
        return rules
    }
}
