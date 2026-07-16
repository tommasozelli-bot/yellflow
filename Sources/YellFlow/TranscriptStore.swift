import Foundation

/// Local, persistent history of transcriptions so text is never lost when the
/// desktop steals focus mid-insert. Backed by a small JSON file in
/// ~/Library/Application Support/YellFlow/history.json. Thread-safe via a
/// serial queue (same pattern as `Log`), safe to call from any thread.
enum TranscriptStore {
    /// One recorded transcription.
    struct Entry: Codable {
        let id: UUID
        let date: Date
        let text: String
    }

    /// Keep only the most recent N entries so the file never grows unbounded.
    private static let cap = 200

    private static let queue = DispatchQueue(label: "yellflow.history")

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static var path: String { fileURL.path }

    /// Append a transcription and persist. No-op for empty/whitespace text.
    static func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Entry(id: UUID(), date: Date(), text: text)
        queue.async {
            var entries = loadUnsafe()
            entries.append(entry)
            if entries.count > cap {
                entries.removeFirst(entries.count - cap)
            }
            saveUnsafe(entries)
        }
    }

    /// Most recent entries first. Returns [] if the file is missing or corrupt.
    static func recent(limit: Int = 50) -> [Entry] {
        queue.sync {
            let sorted = loadUnsafe().sorted { $0.date > $1.date }
            return Array(sorted.prefix(max(0, limit)))
        }
    }

    // MARK: - File I/O (must run on `queue`)

    private static func loadUnsafe() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func saveUnsafe(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
