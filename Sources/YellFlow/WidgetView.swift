import AppKit

/// The popover widget, styled after the Gemini mockup: dark card, monospaced
/// yellow title, hairline separators, yellow icons. Language and engine toggles, a
/// permissions nudge when needed, the history (what was dictated / what was
/// copied, click to copy again) and Quit. All copy is bilingual.
final class WidgetViewController: NSViewController {

    var onLanguageChange: ((String) -> Void)?
    var onEngineChange: ((EngineKind) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Yell Flow")
    private let howtoLabel = NSTextField(wrappingLabelWithString: "")
    private let languageCaption = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: ["Auto", "EN", "IT"], trackingMode: .selectOne, target: nil, action: nil)
    private let engineCaption = NSTextField(labelWithString: "")
    private let engineControl = NSSegmentedControl(labels: ["Parakeet", "Whisper"], trackingMode: .selectOne, target: nil, action: nil)
    private let historyCaption = NSTextField(labelWithString: "")
    private let historyControl = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let permissionRow = NSStackView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let historyScroll = NSScrollView()
    private let historyStack = NSStackView()
    private let historyEmptyLabel = NSTextField(labelWithString: "")
    private let openAllButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        // Taller than the base widget to fit the scrollable history section.
        // The popover ultimately sizes to the pinned stack's fitting height.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 272, height: 456))
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

        // Parakeet: ~10x faster, names fixed afterwards. Whisper: slower, takes the vocabulary as a hint.
        engineCaption.font = .systemFont(ofSize: 13, weight: .medium)
        engineCaption.textColor = .yellFlowText
        engineControl.target = self
        engineControl.action = #selector(engineChanged)
        engineControl.selectedSegment = Self.engines.firstIndex(of: Preferences.engine) ?? 0
        engineControl.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 10.13, *) {
            engineControl.selectedSegmentBezelColor = .yellFlow
        }
        let engineSpacer = NSView()
        engineSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let engineRow = NSStackView(views: [icon("waveform"), engineCaption, engineSpacer, engineControl])
        engineRow.orientation = .horizontal
        engineRow.spacing = 8
        engineRow.alignment = .centerY

        historyCaption.font = .systemFont(ofSize: 13, weight: .medium)
        historyCaption.textColor = .yellFlowText
        historyControl.target = self
        historyControl.action = #selector(historyTabChanged)
        historyControl.selectedSegment = showingClipboard ? 1 : 0
        historyControl.appearance = NSAppearance(named: .darkAqua)
        if #available(macOS 10.13, *) {
            historyControl.selectedSegmentBezelColor = .yellFlow
        }
        let historySpacer = NSView()
        historySpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let historyHeader = NSStackView(views: [icon("clock.arrow.circlepath"), historyCaption, historySpacer, historyControl])
        historyHeader.orientation = .horizontal
        historyHeader.spacing = 8
        historyHeader.alignment = .centerY

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

        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 8
        historyStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        historyStack.translatesAutoresizingMaskIntoConstraints = false

        historyEmptyLabel.font = .systemFont(ofSize: 12)
        historyEmptyLabel.textColor = .yellFlowDim

        historyScroll.hasVerticalScroller = true
        historyScroll.drawsBackground = false
        historyScroll.borderType = .noBorder
        historyScroll.automaticallyAdjustsContentInsets = false
        historyScroll.translatesAutoresizingMaskIntoConstraints = false
        historyScroll.documentView = historyStack
        let clip = historyScroll.contentView
        NSLayoutConstraint.activate([
            historyStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            historyStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            historyStack.topAnchor.constraint(equalTo: clip.topAnchor),
            historyStack.widthAnchor.constraint(equalTo: clip.widthAnchor)
        ])

        openAllButton.target = self
        openAllButton.action = #selector(openAll)
        openAllButton.isBordered = false
        openAllButton.imagePosition = .imageLeading
        openAllButton.image = symbol("doc.text")

        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.isBordered = false
        quitButton.imagePosition = .imageLeading
        quitButton.image = symbol("power")
        quitButton.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [
            titleLabel, hairline(), howtoLabel, langRow, engineRow, permissionRow,
            hairline(), historyHeader, historyScroll, openAllButton, hairline(), quitButton
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
            engineRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            historyHeader.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            historyScroll.widthAnchor.constraint(equalToConstant: 236),
            historyScroll.heightAnchor.constraint(equalToConstant: 220)
        ])

        applyLanguage()
        refreshHistory()
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
        // The popover re-runs this on every open — rebuild the history too.
        refreshHistory()
    }

    private var showingClipboard: Bool { Preferences.historyTab == "copied" }
    private var store: HistoryStore { showingClipboard ? .clipboard : .dictations }

    /// Rebuild the history list from the persistent store (most recent first).
    /// Cleared and reconstructed each time so it never shows stale rows. The
    /// list shows the latest 100; "Open all" has everything.
    private func refreshHistory() {
        historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let total = store.count
        let all = isItalian ? "Apri tutto" : "Open all"
        setTitle(openAllButton, total > 0 ? "\(all) (\(total))" : all)
        openAllButton.isEnabled = total > 0

        let entries = store.recent(limit: 100)
        if entries.isEmpty {
            if showingClipboard {
                historyEmptyLabel.stringValue = isItalian ? "Ancora niente di copiato" : "Nothing copied yet"
            } else {
                historyEmptyLabel.stringValue = isItalian ? "Nessuna trascrizione ancora" : "No transcriptions yet"
            }
            historyStack.addArrangedSubview(historyEmptyLabel)
            historyEmptyLabel.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
            return
        }

        for (i, entry) in entries.enumerated() {
            if i > 0 {
                let divider = historyDivider()
                historyStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
            }
            let row = HistoryRow(entry: entry, italian: isItalian)
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Localization

    private var isItalian: Bool { Preferences.language == "it" }

    private func applyLanguage() {
        if isItalian {
            howtoLabel.stringValue = "Tocca ⌥ destro: registra. Altro tocco: stop,\nil testo appare al cursore."
            languageCaption.stringValue = "Lingua"
            engineCaption.stringValue = "Motore"
            historyCaption.stringValue = "Cronologia"
            historyControl.setLabel("Dettati", forSegment: 0)
            historyControl.setLabel("Copiati", forSegment: 1)
            permissionButton.title = "Apri Impostazioni"
            quitButton.title = "Esci"
        } else {
            howtoLabel.stringValue = "Tap Right ⌥: record. Tap again: stop,\ntext lands at your cursor."
            languageCaption.stringValue = "Language"
            engineCaption.stringValue = "Engine"
            historyCaption.stringValue = "History"
            historyControl.setLabel("Dictated", forSegment: 0)
            historyControl.setLabel("Copied", forSegment: 1)
            permissionButton.title = "Open Settings"
            quitButton.title = "Quit"
        }
        setTitle(quitButton, quitButton.title)
        refreshPermissions()
    }

    private func setTitle(_ button: NSButton, _ title: String) {
        button.title = title
        button.attributedTitle = NSAttributedString(
            string: "  " + title,
            attributes: [.foregroundColor: NSColor.yellFlowText, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
    }

    // MARK: - Actions

    private static let languages = ["auto", "en", "it"] // segment order

    @objc private func languageChanged() {
        let lang = Self.languages[max(0, min(languageControl.selectedSegment, Self.languages.count - 1))]
        Preferences.language = lang
        applyLanguage()
        onLanguageChange?(lang)
    }

    private static let engines: [EngineKind] = [.parakeet, .whisper] // segment order

    @objc private func engineChanged() {
        let kind = Self.engines[max(0, min(engineControl.selectedSegment, Self.engines.count - 1))]
        guard kind != Preferences.engine else { return }
        Preferences.engine = kind
        onEngineChange?(kind)
    }

    @objc private func historyTabChanged() {
        Preferences.historyTab = historyControl.selectedSegment == 1 ? "copied" : "dictated"
        refreshHistory()
    }

    /// The whole history (not just the latest 100) as a text file in TextEdit.
    @objc private func openAll() {
        let title: String
        if showingClipboard {
            title = isItalian ? "Cronologia appunti" : "Clipboard history"
        } else {
            title = isItalian ? "Cronologia dettati" : "Dictation history"
        }
        NSWorkspace.shared.open(store.exportText(title: title))
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

    /// A hairline whose width is pinned by the caller (used between history rows).
    private func historyDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.yellFlowHair.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

// MARK: - History row

/// One transcription in the history list: time + a 2-line preview.
/// Clicking copies the full text to the pasteboard with a brief confirmation.
private final class HistoryRow: NSView {

    private let full: String
    private let italian: Bool
    private let timeLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private var restoreWork: DispatchWorkItem?

    init(entry: HistoryStore.Entry, italian: Bool) {
        self.full = entry.text
        self.italian = italian
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let df = DateFormatter()
        df.dateFormat = Calendar.current.isDateInToday(entry.date) ? "HH:mm" : "dd/MM HH:mm"
        timeLabel.stringValue = df.string(from: entry.date)
        timeLabel.font = .yellFlowMono(10, .regular)
        timeLabel.textColor = .yellFlowDim

        previewLabel.stringValue = entry.text
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .yellFlowText
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.cell?.truncatesLastVisibleLine = true

        let content = NSStackView(views: [timeLabel, previewLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copyText)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)

        // Brief confirmation, then restore the original preview.
        previewLabel.stringValue = italian ? "Copiato ✓" : "Copied ✓"
        previewLabel.textColor = .yellFlow
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.previewLabel.stringValue = self.full
            self.previewLabel.textColor = .yellFlowText
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}
