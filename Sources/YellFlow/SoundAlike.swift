import Foundation

/// The vocabulary for an engine that takes no prompt (Parakeet).
///
/// Whisper is told the user's names BEFORE it decodes. Parakeet has no such
/// input, so the names are applied AFTER: each run of words that sounds like a
/// vocabulary term is replaced by the term as written. Measured on 31/10/2026:
/// "Yell Flow" came out as "gli El Flow" or "gli al floor", differently each
/// time, so a fixed corrections.txt rule could never keep up.
///
/// Two guards keep ordinary words alone: a near match is applied only where the
/// model itself was unsure of a word (token probability under 0.9 — confident
/// tokens sit at 0.98–1.0), and short terms (under 6 sounds) must sound exactly
/// the same. An exact match is always applied: it only fixes the spelling.
enum SoundAlike {

    struct Word {
        let text: String
        /// Lowest token probability in the word, 1 when the model gave none.
        let confidence: Float
    }

    private struct Term {
        let text: String
        let key: [Character]
        let words: Int
    }

    private struct Match {
        let start: Int, length: Int
        let term: Term
        let score: Double
    }

    private static let unsure: Float = 0.9

    /// The words joined back into text, with the vocabulary applied.
    static func apply(_ words: [Word], terms rawTerms: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let terms = prepare(rawTerms)
        let cores = words.map { split($0.text) }
        let keys = cores.map { phonetic($0.core) }

        var matches: [Match] = []
        for start in words.indices {
            for length in 1...4 where start + length <= words.count {
                let span = start..<(start + length)
                let key = Array(span.map { keys[$0] }.joined())
                guard key.count >= 4 else { continue }
                let unsureSpan = span.contains { words[$0].confidence < unsure }
                for term in terms where abs(term.words - length) <= 1 {
                    let longest = max(key.count, term.key.count)
                    let allowed = term.key.count >= 8 ? 0.22 : (term.key.count >= 6 ? 0.18 : 0)
                    let maxEdits = Int(Double(longest) * allowed)
                    guard abs(key.count - term.key.count) <= maxEdits else { continue }
                    let edits = distance(key, term.key, limit: maxEdits)
                    guard edits <= maxEdits else { continue }
                    if edits > 0 && !unsureSpan { continue }
                    matches.append(Match(start: start, length: length, term: term,
                                         score: 1 - Double(edits) / Double(longest)))
                }
            }
        }

        // Best first; on a tie the span closest to the term's own word count.
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return abs($0.length - $0.term.words) < abs($1.length - $1.term.words)
        }
        var taken = [Bool](repeating: false, count: words.count)
        var chosen: [Int: Match] = [:]
        for m in matches {
            let span = m.start..<(m.start + m.length)
            guard !span.contains(where: { taken[$0] }) else { continue }
            span.forEach { taken[$0] = true }
            chosen[m.start] = m
        }

        var out: [String] = []
        var i = 0
        while i < words.count {
            guard let m = chosen[i] else { out.append(words[i].text); i += 1; continue }
            let first = cores[i], last = cores[i + m.length - 1]
            var term = m.term.text
            // A lowercase term at the start of a sentence keeps the capital.
            if let c = first.core.first, c.isUppercase, term == term.lowercased() {
                term = term.prefix(1).uppercased() + term.dropFirst()
            }
            let original = (i..<(i + m.length)).map { cores[$0].core }.joined(separator: " ")
            if original != term {
                Log.write("vocabulary: \"\(original)\" → \"\(term)\"")
            }
            out.append(first.lead + term + last.trail)
            i += m.length
        }
        return out.joined(separator: " ")
    }

    private static func prepare(_ raw: [String]) -> [Term] {
        var seen = Set<[Character]>()
        var terms: [Term] = []
        for text in raw {
            let key = phonetic(text)
            guard key.count >= 4, seen.insert(key).inserted else { continue }
            terms.append(Term(text: text, key: key, words: text.split(separator: " ").count))
        }
        return terms
    }

    /// "«Flow,»" → lead "«", core "Flow", trail ",»". Apostrophes inside stay.
    private static func split(_ word: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(word)
        var a = 0, b = chars.count
        while a < b, !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
        while b > a, !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
        return (String(chars[..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    /// How a word sounds to an Italian ear, roughly: no accents, no silent h,
    /// English spellings folded (y→i, w→u, k→c, ph→f, ee→i, oo→u, ow→o),
    /// doubled letters collapsed, spaces and punctuation gone.
    static func phonetic(_ text: String) -> [Character] {
        var s = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for (from, to) in [("ph", "f"), ("ck", "c"), ("ee", "i"), ("ea", "i"), ("oo", "u"), ("ow", "o"),
                           ("k", "c"), ("q", "c"), ("w", "u"), ("y", "i"), ("j", "i"), ("x", "cs"), ("h", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var out: [Character] = []
        for c in s where c.isLetter || c.isNumber {
            if out.last != c { out.append(c) }
        }
        return out
    }

    /// Edit distance, giving up (returning limit + 1) once it can't stay within limit.
    private static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a == b { return 0 }
        if limit == 0 { return 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(1, a.count) where !a.isEmpty {
            cur[0] = i
            var best = cur[0]
            for j in 1...max(1, b.count) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                best = min(best, cur[j])
            }
            if best > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
