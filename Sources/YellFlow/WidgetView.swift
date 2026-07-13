import AppKit

/// The popover widget, styled after the Gemini mockup: dark card, monospaced
/// yellow title, hairline separators, yellow icons. Functionality is unchanged —
/// IT/EN toggle, a permissions nudge when needed, and Quit. All copy is bilingual.
final class WidgetViewController: NSViewController {

    var onLanguageChange: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Yell Flow")
    private let howtoLabel = NSTextField(wrappingLabelWithString: "")
    private let languageCaption = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: ["Auto", "EN", "IT"], trackingMode: .selectOne, target: nil, action: nil)
    private let voiceCaption = NSTextField(labelWithString: "")
    private let voiceControl = NSSegmentedControl(labels: ["F", "M"], trackingMode: .selectOne, target: nil, action: nil)
    private let permissionRow = NSStackView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 272, height: 244))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.yellFlowInk.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        titleLabel.font = .yellFlowMono(19, .heavy)
        titleLabel.textColor = .yellFlow

        howtoLabel.font = .systemFont(ofSize: 12)
        howtoLabel.textColor = .yellFlowDim

        languageCaption.font = .systemFont(ofSize: 13, weight: .medium)
        languageCaption.textColor = .yellFlowText

        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.selectedSegment = Self.languages.firstIndex(of: Preferences.language) ?? 0
        languageControl.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 10.13, *) {
            languageControl.selectedSegmentBezelColor = .yellFlow
        }

        let langSpacer = NSView()
        langSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let langRow = NSStackView(views: [icon("slider.horizontal.3"), languageCaption, langSpacer, languageControl])
        langRow.orientation = .horizontal
        langRow.spacing = 8
        langRow.alignment = .centerY

        voiceCaption.font = .systemFont(ofSize: 13, weight: .medium)
        voiceCaption.textColor = .yellFlowText
        voiceControl.target = self
        voiceControl.action = #selector(voiceChanged)
        voiceControl.selectedSegment = (Preferences.voiceGender == "m") ? 1 : 0
        voiceControl.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 10.13, *) {
            voiceControl.selectedSegmentBezelColor = .yellFlow
        }
        let voiceSpacer = NSView()
        voiceSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let voiceRow = NSStackView(views: [icon("speaker.wave.2"), voiceCaption, voiceSpacer, voiceControl])
        voiceRow.orientation = .horizontal
        voiceRow.spacing = 8
        voiceRow.alignment = .centerY

        permissionLabel.font = .systemFont(ofSize: 11)
        permissionLabel.textColor = NSColor.systemOrange
        permissionLabel.maximumNumberOfLines = 2
        permissionButton.target = self
        permissionButton.action = #selector(openSettings)
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionRow.orientation = .vertical
        permissionRow.alignment = .leading
        permissionRow.spacing = 4
        permissionRow.addArrangedSubview(permissionLabel)
        permissionRow.addArrangedSubview(permissionButton)

        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.isBordered = false
        quitButton.imagePosition = .imageLeading
        quitButton.image = symbol("power")
        quitButton.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [
            titleLabel, hairline(), howtoLabel, langRow, voiceRow, permissionRow, hairline(), quitButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            langRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            voiceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)
        ])

        applyLanguage()
    }

    /// Refresh the permission nudge each time the widget appears.
    func refreshPermissions() {
        let ok = PermissionsHelper.allGranted
        permissionRow.isHidden = ok
        if !ok {
            var missing: [String] = []
            if !PermissionsHelper.hasAccessibility { missing.append("Accessibility") }
            if !PermissionsHelper.hasInputMonitoring { missing.append("Input Monitoring") }
            if !PermissionsHelper.hasMicrophone { missing.append("Microphone") }
            let prefix = isItalian ? "Concedi: " : "Grant: "
            permissionLabel.stringValue = prefix + missing.joined(separator: ", ")
        }
    }

    // MARK: - Localization

    private var isItalian: Bool { Preferences.language == "it" }

    private func applyLanguage() {
        if isItalian {
            howtoLabel.stringValue = "Tieni ⌥ destro: detti, il testo appare al cursore.\nTap su ⌥ con testo selezionato: lo legge."
            languageCaption.stringValue = "Lingua"
            voiceCaption.stringValue = "Voce"
            permissionButton.title = "Apri Impostazioni"
            quitButton.title = "Esci"
        } else {
            howtoLabel.stringValue = "Hold Right ⌥: dictate, text lands at your cursor.\nTap ⌥ with text selected: hear it out loud."
            languageCaption.stringValue = "Language"
            voiceCaption.stringValue = "Voice"
            permissionButton.title = "Open Settings"
            quitButton.title = "Quit"
        }
        quitButton.attributedTitle = NSAttributedString(
            string: "  " + quitButton.title,
            attributes: [.foregroundColor: NSColor.yellFlowText, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        refreshPermissions()
    }

    // MARK: - Actions

    private static let languages = ["auto", "en", "it"] // segment order

    @objc private func languageChanged() {
        let lang = Self.languages[max(0, min(languageControl.selectedSegment, Self.languages.count - 1))]
        Preferences.language = lang
        applyLanguage()
        onLanguageChange?(lang)
    }

    @objc private func voiceChanged() {
        Preferences.voiceGender = voiceControl.selectedSegment == 1 ? "m" : "f"
    }

    @objc private func openSettings() {
        PermissionsHelper.openFirstMissingSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Building blocks

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.yellFlowHair.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 236).isActive = true
        return line
    }

    private func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.yellFlow]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    private func icon(_ name: String) -> NSImageView {
        let iv = NSImageView(image: symbol(name) ?? NSImage())
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return iv
    }
}
