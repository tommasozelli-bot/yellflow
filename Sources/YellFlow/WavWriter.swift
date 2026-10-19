import Foundation

/// Writes 16 kHz mono Float32 samples as a 16-bit PCM WAV file.
/// Used to keep the LAST dictation on disk (Application Support/last-recording.wav)
/// so a misheard word can be replayed through the engine with different
/// settings: `YellFlow --model … --wav last-recording.wav`.
enum WavWriter {

    static func write(samples: [Float], to url: URL, sampleRate: Int = 16_000) {
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        let dataBytes = UInt32(samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1))                       // PCM, mono
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)) // byte rate
        put(UInt16(2)); put(UInt16(16))                      // block align, bits
        data.append(contentsOf: Array("data".utf8)); put(dataBytes)
        for s in samples {
            put(Int16(max(-1, min(1, s)) * 32767))
        }
        try? data.write(to: url, options: .atomic)
    }
}
