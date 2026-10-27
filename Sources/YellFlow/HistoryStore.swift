import Foundation

/// Local, persistent, UNBOUNDED history: everything dictated and everything
/// copied, never dropped. Two instances, one JSON file each in
/// ~/Library/Application Support/YellFlow/ (history.json, clipboard.json).
///
/// Oct 2026: a 9-minute dictation vanished (a new take started while the old
/// one was finishing, and its result was thrown away) and the history kept only
/// the last 200 entries. Now dictations are saved piece by piece while the user
/// is still talking (`upsert` on the take's id), and nothing is ever trimmed.
///
/// Thread-safe via a serial queue, safe to call from any thread. Entries are
/// cached in memory after the first read, so a write never re-parses the file.
final class HistoryStore {
    /// One dictation or one copied text.
    struct Entry: Codable {
        let id: UUID
        let date: Date
        let text: String
    }

    static let dictations = HistoryStore(fileName: "history.json")
    static let clipboard = HistoryStore(fileName: "clipboard.json")

    private let queue: DispatchQueue
    private let fileURL: URL
    private var cache: [Entry]?

    private init(fileName: String) {
        queue = DispatchQueue(label: "yellflow.history.\(fileName)")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(fileName)
    }

    var path: String { fileURL.path }

    /// Append a new entry. No-op for empty/whitespace text.
    func add(_ text: String) {
        guard !Self.isBlank(text) else { return }
        let entry = Entry(id: UUID(), date: Date(), text: text)
        queue.async {
            var entries = self.loadUnsafe()
            entries.append(entry)
            self.saveUnsafe(entries)
        }
    }

    /// Insert or replace the entry with this id, keeping its original date and
    /// position. Used to save a dictation while it's still being recorded.
    func upsert(id: UUID, date: Date, text: String) {
        guard !Self.isBlank(text) else { return }
        let entry = Entry(id: id, date: date, text: text)
        queue.async {
            var entries = self.loadUnsafe()
            if let i = entries.firstIndex(where: { $0.id == id }) {
                guard entries[i].text != text else { return }
                entries[i] = entry
            } else {
                entries.append(entry)
            }
            self.saveUnsafe(entries)
        }
    }

    /// Append, removing any older identical entry first: copying the same text
    /// twice just brings it back to the top.
    func addMovingToTop(_ text: String) {
        guard !Self.isBlank(text) else { return }
        let entry = Entry(id: UUID(), date: Date(), text: text)
        queue.async {
            var entries = self.loadUnsafe()
            if entries.last?.text == text { return }
            entries.removeAll { $0.text == text }
            entries.append(entry)
            self.saveUnsafe(entries)
        }
    }

    /// Most recent entries first. Returns [] if the file is missing or corrupt.
    func recent(limit: Int) -> [Entry] {
        queue.sync { Array(sortedUnsafe().prefix(max(0, limit))) }
    }

    var count: Int { queue.sync { loadUnsafe().count } }

    /// The whole history as readable text, most recent first, written next to
    /// the JSON file. Returns the file's URL.
    func exportText(title: String) -> URL {
        queue.sync {
            let df = DateFormatter()
            df.dateFormat = "dd/MM/yyyy HH:mm"
            let body = sortedUnsafe()
                .map { "\(df.string(from: $0.date))\n\($0.text)" }
                .joined(separator: "\n\n")
            let url = fileURL.deletingLastPathComponent().appendingPathComponent("\(title).txt")
            try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - File I/O (must run on `queue`)

    private func sortedUnsafe() -> [Entry] {
        loadUnsafe().sorted { $0.date > $1.date }
    }

    private func loadUnsafe() -> [Entry] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else { cache = []; return [] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            // Never overwrite a file we couldn't read: set it aside first.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Log.write("⚠️ \(fileURL.lastPathComponent) unreadable — moved to \(aside.lastPathComponent)")
            cache = []
            return []
        }
        cache = entries
        return entries
    }

    private func saveUnsafe(_ entries: [Entry]) {
        cache = entries
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.write("⚠️ could not save \(fileURL.lastPathComponent): \(error)")
        }
    }
}
