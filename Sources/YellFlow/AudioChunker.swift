import Foundation

/// Cuts a dictation into pieces Whisper can swallow in a single 30 s window,
/// choosing the cut points inside pauses so no word is ever split in two.
///
/// Why: whisper.cpp processes fixed 30 s windows. Without timestamps it simply
/// hops 30 s at a time, and whatever word straddles the boundary is chopped —
/// verified on a 70 s clip where a whole clause at t≈30 s vanished. Cutting at
/// pauses removes the problem and, as a bonus, lets long dictations be
/// transcribed piece by piece WHILE the user is still talking.
///
/// Samples are 16 kHz mono Float32.
enum AudioChunker {

    static let sampleRate = 16_000
    /// Don't cut before this much audio is pending: shorter pieces cost the same
    /// fixed encoder pass as a full window, so they only add work.
    static let minChunkSeconds = 20.0
    /// Hard ceiling — must stay under Whisper's 30 s window.
    static let maxChunkSeconds = 28.0
    /// A pause is at least this long (people pause often; 400 ms catches them
    /// without cutting inside the natural gaps between words).
    static let pauseSeconds = 0.4
    /// RMS analysis frame.
    private static let frameSeconds = 0.02

    /// Streaming rule, evaluated every few hundred ms on the audio pending since
    /// the last cut. Returns the sample index where to cut, or nil to keep
    /// waiting.
    ///   - ≥ minChunkSeconds and the tail is a pause → cut at the tail
    ///   - ≥ maxChunkSeconds → cut at the quietest stretch of the last 8 s
    static func streamingCut(_ pending: [Float]) -> Int? {
        let seconds = Double(pending.count) / Double(sampleRate)
        guard seconds >= minChunkSeconds else { return nil }

        let frames = frameRMS(pending)
        let threshold = silenceThreshold(frames)
        let pauseFrames = Int(pauseSeconds / frameSeconds)

        if frames.count >= pauseFrames, frames.suffix(pauseFrames).allSatisfy({ $0 < threshold }) {
            // Leave half the pause on each side so neither piece starts on speech.
            return pending.count - pauseFrames / 2 * frameLength
        }
        guard seconds >= maxChunkSeconds else { return nil }
        let searchFrames = min(frames.count, Int(8.0 / frameSeconds))
        return quietestCut(frames: frames, from: frames.count - searchFrames)
    }

    /// Offline rule: splits an already-recorded buffer into ≤ maxChunkSeconds
    /// pieces cut inside pauses. Buffers that already fit come back untouched.
    static func split(_ samples: [Float]) -> [[Float]] {
        let maxSamples = Int(maxChunkSeconds) * sampleRate
        guard samples.count > maxSamples else { return [samples] }

        let frames = frameRMS(samples)
        let threshold = silenceThreshold(frames)
        let minFrames = Int(minChunkSeconds / frameSeconds)
        let maxFrames = Int(maxChunkSeconds / frameSeconds)
        let pauseFrames = Int(pauseSeconds / frameSeconds)

        var pieces: [[Float]] = []
        var start = 0 // frame index
        while frames.count - start > maxFrames {
            // Prefer the LAST full pause inside [start+min, start+max]: bigger pieces, fewer passes.
            var cutFrame: Int?
            var run = 0
            var f = start + minFrames
            while f < start + maxFrames {
                run = frames[f] < threshold ? run + 1 : 0
                if run >= pauseFrames { cutFrame = f - pauseFrames / 2 }
                f += 1
            }
            let cut = cutFrame ?? quietestFrame(frames: frames, from: start + minFrames, to: start + maxFrames)
            pieces.append(Array(samples[start * frameLength ..< cut * frameLength]))
            start = cut
        }
        pieces.append(Array(samples[(start * frameLength)...]))
        return pieces
    }

    /// The first `seconds` of audio counted from the moment speech starts, so a
    /// long pause after the tap doesn't feed silence to language detection.
    static func fromSpeechOnset(_ samples: [Float], seconds: Double) -> [Float] {
        let frames = frameRMS(samples)
        let threshold = silenceThreshold(frames)
        let onset = (frames.firstIndex { $0 >= threshold } ?? 0) * frameLength
        let end = min(samples.count, onset + Int(seconds * Double(sampleRate)))
        return Array(samples[onset..<end])
    }

    // MARK: - Internals

    private static var frameLength: Int { Int(frameSeconds * Double(sampleRate)) }

    private static func frameRMS(_ samples: [Float]) -> [Float] {
        let n = frameLength
        var out: [Float] = []
        out.reserveCapacity(samples.count / n)
        var i = 0
        while i + n <= samples.count {
            var sum: Float = 0
            for j in i..<(i + n) { sum += samples[j] * samples[j] }
            out.append((sum / Float(n)).squareRoot())
            i += n
        }
        return out
    }

    /// Silence is relative to how loud this take is (mic gain, distance), with an
    /// absolute floor above typical room noise (≈0.002).
    private static func silenceThreshold(_ frames: [Float]) -> Float {
        guard !frames.isEmpty else { return 0.004 }
        let sorted = frames.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return max(0.004, p90 * 0.12)
    }

    /// Centre of the quietest `pauseSeconds`-long window in [from, end).
    private static func quietestFrame(frames: [Float], from: Int, to: Int) -> Int {
        let win = Int(pauseSeconds / frameSeconds)
        let end = min(to, frames.count)
        guard end - from > win else { return max(from, end - 1) }
        var best = from
        var bestSum = Float.greatestFiniteMagnitude
        var sum: Float = 0
        for f in from..<(from + win) { sum += frames[f] }
        bestSum = sum
        var f = from + win
        while f < end {
            sum += frames[f] - frames[f - win]
            if sum < bestSum { bestSum = sum; best = f - win + 1 }
            f += 1
        }
        return best + win / 2
    }

    private static func quietestCut(frames: [Float], from: Int) -> Int {
        quietestFrame(frames: frames, from: from, to: frames.count) * frameLength
    }
}
