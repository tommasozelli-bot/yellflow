import Foundation

/// Minimal file logger so a stuck/odd run can be diagnosed after the fact.
/// Writes to ~/Library/Application Support/YellFlow/yellflow.log (and NSLog).
enum Log {
    private static let queue = DispatchQueue(label: "yellflow.log")

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YellFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("yellflow.log")
    }()

    static var path: String { fileURL.path }

    static func write(_ message: String) {
        NSLog("YellFlow: \(message)")
        let line = "\(Self.timestamp())  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
