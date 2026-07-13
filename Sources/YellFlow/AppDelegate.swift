import AppKit
import ApplicationServices
import IOKit.hid

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let widget = WidgetViewController()
    private let indicator = RecordingIndicator()

    private var engine: WhisperEngine?
    private var controller: DictationController?
    private let speech = SpeechEngine()
    private let selectionQueue = DispatchQueue(label: "yellflow.selection", qos: .userInitiated)
    private var spaceMonitors: [Any] = []
    private var hotkeyActive = false
    private var lastState: DictationController.State = .idle

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
        loadEngine()
        setupReadAloud()

        requestAllPermissions()
        controller?.warmUp()
        startHotkeyIfPossible()
    }

    /// Fire the system prompts for all three permissions on first launch, each of
    /// which deep-links the user straight to the right toggle.
    private func requestAllPermissions() {
        controller?.requestMicPermission { granted in Log.write("microphone granted: \(granted)") }
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

    // MARK: - Read-aloud wiring

    private func setupReadAloud() {
        controller?.onTap = { [weak self] in self?.handleTap() }
        controller?.onRecordingWillStart = { [weak self] in self?.speech.stop() }
        speech.onStateChange = { [weak self] speaking in self?.setSpeaking(speaking) }
    }

    /// Tap of Right ⌥: read the selected text aloud — or stop if already speaking.
    private func handleTap() {
        if speech.isSpeaking {
            speech.stop()
            Log.write("tap: stopped speech")
            return
        }
        // Grabbing the selection can wait up to ~0.9 s (⌘C fallback in Electron
        // apps) — never block the main thread for that.
        selectionQueue.async { [weak self] in
            let text = SelectionReader.selectedText()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let text else {
                    Log.write("tap: no selected text — nothing to read")
                    return
                }
                self.speech.speak(text, fallbackLanguage: Preferences.language)
            }
        }
    }

    /// While speech is playing, pressing SPACE anywhere kills it outright.
    private func updateSpaceMonitor(active: Bool) {
        if active && spaceMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                if event.keyCode == 49 { // space
                    self?.speech.stop()
                    Log.write("space pressed — speech terminated")
                }
            }) { spaceMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                if event.keyCode == 49 { self?.speech.stop() }
                return event
            }) { spaceMonitors.append(local) }
        } else if !active {
            spaceMonitors.forEach { NSEvent.removeMonitor($0) }
            spaceMonitors.removeAll()
        }
    }

    private func setSpeaking(_ speaking: Bool) {
        updateSpaceMonitor(active: speaking)
        guard let button = statusItem.button else { return }
        if speaking {
            setMenuSpinner(false)
            button.image = statusImage(symbol: "speaker.wave.2.fill", tinted: true)
        } else if lastState == .idle {
            button.image = statusImage(symbol: "mic.circle", tinted: false)
        }
    }

    private func setState(_ state: DictationController.State) {
        lastState = state
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

    private func loadEngine() {
        guard let path = modelPath() else {
            showFatal("Model not found",
                      "whisper-model.bin is missing from the app bundle. Rebuild with build.sh.")
            return
        }
        do {
            let engine = try WhisperEngine(modelPath: path)
            self.engine = engine
            let controller = DictationController(engine: engine, language: Preferences.language)
            controller.onStateChange = { [weak self] state in self?.setState(state) }
            self.controller = controller
            Log.write("engine loaded from \(path)")
        } catch {
            showFatal("Could not load the model", "\(error)")
        }
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
