import AVFoundation
import AppKit
import Foundation

// Entry point.
//   YellFlow                             -> launch the menu-bar widget (packaged app)
//   YellFlow --model M.bin --wav A.wav   -> offline self-test, no permissions needed
//   YellFlow --speak "text" [--gender m|f] -> read-aloud self-test (no model needed)

// MARK: - Read-aloud self-test (runs before anything else; needs no model)

if let speakIdx = CommandLine.arguments.firstIndex(of: "--speak"), speakIdx + 1 < CommandLine.arguments.count {
    let cli = CommandLine.arguments
    if let gIdx = cli.firstIndex(of: "--gender"), gIdx + 1 < cli.count {
        Preferences.voiceGender = cli[gIdx + 1]
    }
    let speech = SpeechEngine()
    var finished = false
    speech.onStateChange = { speaking in if !speaking { finished = true } }
    speech.speak(cli[speakIdx + 1], fallbackLanguage: "en")
    let deadline = Date().addingTimeInterval(60)
    while !finished && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    print(finished ? "spoke OK (see log for voice/language)" : "⏱️ speech did not finish")
    exit(finished ? 0 : 1)
}

// MARK: - Offline self-test helpers

func loadAudioFileAs16kMono(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw NSError(domain: "yellflow.selftest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot build converter"])
    }
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
    var out: [Float] = []
    var reachedEnd = false
    while true {
        let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if reachedEnd { outStatus.pointee = .endOfStream; return nil }
            inBuf.frameLength = 0
            do { try file.read(into: inBuf) } catch {
                reachedEnd = true; outStatus.pointee = .endOfStream; return nil
            }
            if inBuf.frameLength == 0 {
                reachedEnd = true; outStatus.pointee = .endOfStream; return nil
            }
            outStatus.pointee = .haveData
            return inBuf
        }
        if outBuf.frameLength > 0, let channel = outBuf.floatChannelData {
            out.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outBuf.frameLength)))
        }
        if status == .endOfStream || status == .error || convError != nil { break }
    }
    return out
}

func runSelfTest(modelPath: String, wavPath: String, language: String, background: Bool) -> Never {
    func work() -> Int32 {
        do {
            let engine = try WhisperEngine(modelPath: modelPath)
            let samples = try loadAudioFileAs16kMono(url: URL(fileURLWithPath: wavPath))
            print("Loaded \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000))s)")
            let raw = engine.transcribe(samples: samples, language: language, vocabulary: Vocabulary.prompt())
            print("Transcript: \(TextCleanup.clean(raw))")
            return raw.isEmpty ? 2 : 0
        } catch {
            print("❌ Self-test failed: \(error)")
            return 1
        }
    }
    if !background { exit(work()) }

    // Faithfully mirror the GUI: engine created on MAIN, transcription on a background
    // queue while a run loop spins on main.
    guard let engine = try? WhisperEngine(modelPath: modelPath),
          let samples = try? loadAudioFileAs16kMono(url: URL(fileURLWithPath: wavPath)) else {
        print("❌ setup failed"); exit(1)
    }
    print("Loaded \(samples.count) samples")
    let qosName = ProcessInfo.processInfo.environment["YELLFLOW_QOS"] ?? "userInitiated"
    let qos: DispatchQoS.QoSClass = (qosName == "ui") ? .userInteractive : .userInitiated
    var finished = false
    let t0 = Date()
    DispatchQueue.global(qos: qos).async {
        let raw = engine.transcribe(samples: samples, language: language, vocabulary: Vocabulary.prompt())
        DispatchQueue.main.async {
            print("Transcript: \(TextCleanup.clean(raw))  [\(String(format: "%.1f", Date().timeIntervalSince(t0)))s, qos=\(qosName)]")
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    CFRunLoopRunInMode(.defaultMode, 120, false)
    if !finished { print("⏱️ TIMEOUT: background transcribe hung"); exit(3) }
    exit(0)
}

// MARK: - Dispatch

let argv = CommandLine.arguments
if let wavIdx = argv.firstIndex(of: "--wav"), wavIdx + 1 < argv.count {
    var model = ""
    if let mIdx = argv.firstIndex(of: "--model"), mIdx + 1 < argv.count { model = argv[mIdx + 1] }
    guard !model.isEmpty else {
        print("Usage: YellFlow --model <ggml-model.bin> --wav <audio-file> [--lang auto|it|en]")
        exit(1)
    }
    var lang = "auto"
    if let lIdx = argv.firstIndex(of: "--lang"), lIdx + 1 < argv.count { lang = argv[lIdx + 1] }
    runSelfTest(modelPath: model, wavPath: argv[wavIdx + 1], language: lang, background: argv.contains("--bg"))
}

// GUI: menu-bar widget, no Dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
