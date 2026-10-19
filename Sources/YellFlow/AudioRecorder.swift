import AVFoundation

/// Captures microphone audio and returns it as 16 kHz mono Float32 in [-1, 1],
/// which is exactly what whisper.cpp expects.
///
/// The AVAudioEngine input tap runs at the *hardware* format (typically 44.1/48 kHz,
/// possibly multi-channel); every buffer is pushed through a persistent
/// AVAudioConverter that resamples + downmixes to the target format.
final class AudioRecorder {

    enum AudioRecorderError: Error {
        case noInputDevice
        case converterCreationFailed
    }

    /// 16 kHz mono Float32 non-interleaved — whisper.cpp's required input format.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var isRunning = false

    /// Fires ~10-20x/s with the RMS level (0…1) of each converted buffer,
    /// always marshaled to main so the UI can drive a live waveform.
    /// The RMS math runs on the audio thread; only the callback hops to main.
    var onLevel: ((Float) -> Void)?

    // MARK: - Permission

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Recording

    func start() throws {
        guard !isRunning else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        // Query the hardware format at every start — the user may have switched microphones.
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.convertAndAppend(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw error
        }
        isRunning = true
    }

    /// Hands over what has been captured since the last `take()`/`start()`
    /// WITHOUT stopping — the controller transcribes long dictations piece by
    /// piece while the user is still talking.
    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    /// Stops the engine and returns everything recorded since the last
    /// `take()`/`start()`, as 16 kHz mono Float32 in [-1, 1].
    func stop() -> [Float] {
        guard isRunning else {
            lock.lock(); defer { lock.unlock() }
            return samples
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        // Flush the resampler's internal tail so we don't drop the last few ms.
        if let converter {
            let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if error == nil { append(out) }
        }
        converter = nil

        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    // MARK: - Conversion

    private func convertAndAppend(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Output frame count follows the sample-rate ratio — never assume 1:1.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block must hand the buffer over exactly once per convert() call.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return }
        append(out)
        emitLevel(out)
    }

    /// Computes the RMS of a converted buffer and reports it on main.
    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, buffer.frameLength > 0, let channel = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let ptr = UnsafeBufferPointer(start: channel[0], count: count)
        var sum: Float = 0
        for sample in ptr { sum += sample * sample }
        let rms = (sum / Float(count)).squareRoot()
        DispatchQueue.main.async { onLevel(rms) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData else { return }
        let ptr = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        lock.lock()
        samples.append(contentsOf: ptr)
        lock.unlock()
    }
}
