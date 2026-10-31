import AppKit
import ApplicationServices
import IOKit.hid

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let widget = WidgetViewController()
    private let indicator = RecordingIndicator()

    private var engine: SpeechEngine?
    private var controller: DictationController?
    private var hotkeyActive = false

    private lazy var menuSpinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch — log at \(Log.path)")
        setupStatusItem()
        setupPopover()
        ClipboardHistory.start()
        requestAllPermissions()
        loadEngine()
    }

    /// Fire the system prompts for all three permissions on first launch, each of
    /// which deep-links the user straight to the right toggle.
    private func requestAllPermissions() {
        AudioRecorder().requestPermission { granted in Log.write("microphone granted: \(granted)") }
        // Accessibility (needed to paste into other apps): shows the system dialog.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        Log.write("accessibility trusted: \(AXIsProcessTrustedWithOptions(prompt))")
        // Input Monitoring (needed for the global Right ⌥ shortcut).
        Log.write("input-monitoring requested: \(IOHIDRequestAccess(kIOHIDRequestTypeListenEvent))")
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusImage(symbol: "mic.circle", tinted: false)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    private func statusImage(symbol: String, tinted: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Yell Flow") else { return nil }
        if tinted {
            let tint = config.applying(.init(paletteColors: [.black, .yellFlow]))
            let img = base.withSymbolConfiguration(tint) ?? base
            img.isTemplate = false
            return img
        }
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = true
        return img
    }

    private func setMenuSpinner(_ show: Bool) {
        guard let button = statusItem.button else { return }
        if show {
            button.image = nil
            if menuSpinner.superview == nil {
                button.addSubview(menuSpinner)
                NSLayoutConstraint.activate([
                    menuSpinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    menuSpinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    menuSpinner.widthAnchor.constraint(equalToConstant: 15),
                    menuSpinner.heightAnchor.constraint(equalToConstant: 15)
                ])
            }
            menuSpinner.startAnimation(nil)
        } else {
            menuSpinner.stopAnimation(nil)
            menuSpinner.removeFromSuperview()
        }
    }

    private func setState(_ state: DictationController.State) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            setMenuSpinner(false)
            button.image = statusImage(symbol: "mic.circle", tinted: false)
            indicator.hide()
        case .recording:
            setMenuSpinner(false)
            button.image = statusImage(symbol: "mic.circle.fill", tinted: true)
            indicator.showListening()
        case .transcribing:
            indicator.showTranscribing()
            setMenuSpinner(true) // loading indicator in the menu bar
        }
    }

    // MARK: - Popover widget

    private func setupPopover() {
        widget.onLanguageChange = { [weak self] lang in
            self?.controller?.language = lang
            Log.write("language set to \(lang)")
        }
        widget.onEngineChange = { [weak self] kind in
            Log.write("engine set to \(kind.rawValue)")
            self?.reloadEngine()
        }
        popover.contentViewController = widget
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua) // dark card + arrow
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            startHotkeyIfPossible() // retry in case permissions were just granted
            widget.refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Engine wiring

    /// Loads the model off the main thread: with the Core ML encoder the very
    /// first launch compiles it (~45 s) and the menu bar must not freeze. The
    /// spinner shows until the engine is ready; hotkey and warm-up follow.
    /// Parakeet is the default; without its model the app falls back to Whisper.
    private func loadEngine() {
        var kind = Preferences.engine
        if kind == .parakeet && parakeetModelPath() == nil {
            Log.write("⚠️ Parakeet model not found — using Whisper")
            kind = .whisper
        }
        guard let path = kind == .parakeet ? parakeetModelPath() : modelPath() else {
            showFatal("Model not found",
                      "whisper-model.bin is missing from the app bundle. Rebuild with build.sh.")
            return
        }
        setMenuSpinner(true)
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let engine: SpeechEngine
                let detail: String
                if kind == .parakeet {
                    let parakeet = try ParakeetEngine(modelPath: path)
                    (engine, detail) = (parakeet, "backend: \(parakeet.backend)")
                } else {
                    let whisper = try WhisperEngine(modelPath: path)
                    (engine, detail) = (whisper, "encoder: \(whisper.encoderBackend)")
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.engine = engine
                    let controller = DictationController(engine: engine, language: Preferences.language)
                    controller.onStateChange = { [weak self] state in self?.setState(state) }
                    controller.onLevel = { [weak self] rms in self?.indicator.updateLevel(rms) }
                    self.controller = controller
                    Log.write("\(engine.name) loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, \(detail)")
                    self.setMenuSpinner(false)
                    controller.warmUp()
                    self.startHotkeyIfPossible()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setMenuSpinner(false)
                    self?.showFatal("Could not load the model", "\(error)")
                }
            }
        }
    }

    /// The engine picked in the widget: the old one is released first, so the
    /// two models are never in memory together (8 GB Macs).
    private func reloadEngine() {
        controller?.stop()
        controller = nil
        engine = nil
        hotkeyActive = false
        setState(.idle)
        loadEngine()
    }

    private func startHotkeyIfPossible() {
        guard !hotkeyActive, let controller else { return }
        do {
            try controller.start()
            hotkeyActive = true
        } catch {
            hotkeyActive = false
            Log.write("hotkey not installed yet (grant Accessibility / Input Monitoring)")
        }
    }

    private func modelPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["YELLFLOW_MODEL"], !override.isEmpty {
            return override
        }
        // Generic resource name so swapping models is a build.sh change only;
        // "ggml-small" kept as fallback for bundles built before the rename.
        return Bundle.main.url(forResource: "whisper-model", withExtension: "bin")?.path
            ?? Bundle.main.url(forResource: "ggml-small", withExtension: "bin")?.path
    }

    /// Bundled as parakeet-model.gguf; YELLFLOW_PARAKEET_MODEL overrides it, and
    /// a copy downloaded into Application Support/YellFlow/models works too.
    private func parakeetModelPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["YELLFLOW_PARAKEET_MODEL"], !override.isEmpty {
            return override
        }
        if let bundled = Bundle.main.url(forResource: "parakeet-model", withExtension: "gguf")?.path {
            return bundled
        }
        let downloaded = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YellFlow/models/parakeet-ultra-Q8_0.gguf").path
        return FileManager.default.fileExists(atPath: downloaded) ? downloaded : nil
    }

    private func showFatal(_ title: String, _ message: String) {
        Log.write("FATAL: \(title) — \(message)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
