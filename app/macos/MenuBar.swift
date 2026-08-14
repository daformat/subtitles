// Status bar item — the app's only chrome.
//
// The app is LSUIElement (no Dock icon, no menu bar of its own), so this is where
// everything the user can change lives: what to listen to, text size, overlay
// position, permission state, and quit.
//
// The source submenu is rebuilt every time the menu opens, because "which apps
// are playing audio right now" is exactly the kind of thing that is stale a second
// after you cache it.

import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// Health badge, drawn as a subview rather than composited into the icon.
    /// Compositing would force `isTemplate = false`, and the icon would then stop
    /// adapting to light/dark menu bars; a subview keeps the template intact.
    private lazy var alertDot: NSView = {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        return dot
    }()

    /// Shown while a model is downloading or loading — same size and corner as
    /// `alertDot`, blue because this is work in progress rather than a fault. A
    /// first-run download is minutes long; without something moving in the menu
    /// bar the app is indistinguishable from hung.
    ///
    /// A pulsing dot rather than an `NSProgressIndicator`: at 6pt a spinner
    /// renders as an illegible grey smudge against the menu bar, while a pulse
    /// reads as "working" at any size.
    private lazy var busyDot: NSView = {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = 3
        return dot
    }()

    private func startPulse() {
        guard busyDot.layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        busyDot.layer?.add(pulse, forKey: "pulse")
    }

    /// Live while the menu is open during a load, because a menu's contents are
    /// otherwise frozen for as long as it is on screen.
    private var progressTimer: Timer?
    private weak var progressView: ProgressMenuView?
    /// The item holding that view, so it can be swapped out in place when the
    /// load finishes with the menu still open.
    private weak var progressItem: NSMenuItem?

    /// When the current load started, and how long it has to run before it is
    /// worth badging.
    ///
    /// A cached model loads in a couple of seconds, so without the delay every
    /// single launch flashed the badge on and straight back off — which reads as
    /// a glitch rather than as progress. Work that finishes inside the delay is
    /// never announced at all.
    private var busySince: Date?
    private let busyBadgeDelay: TimeInterval = 1.5

    // Wired up by main.swift.
    var onTogglePause: (() -> Void)?
    var onSelectSource: ((AudioSource) -> Void)?
    var onSelectVariant: ((FluidVariant) -> Void)?
    var onSelectLanguage: ((FluidLanguage) -> Void)?
    var currentLanguageID: () -> String = { FluidLanguage.auto.rawValue }
    var onToggleSpeakerBreaks: (() -> Void)?
    var onToggleVAD: (() -> Void)?
    var vadEnabled: () -> Bool = { true }
    var speakerBreaksEnabled: () -> Bool = { false }
    var onFontSize: ((CGFloat) -> Void)?
    var onResetPosition: (() -> Void)?
    var onQuit: (() -> Void)?

    var isPaused: () -> Bool = { false }
    var currentSource: () -> AudioSource = { .allSystemAudio }
    var currentFontSize: () -> CGFloat = { 30 }
    var currentVariantID: () -> String = { "" }
    /// Non-nil while a model is downloading or loading; disables the picker.
    var engineBusy: () -> String? = { nil }
    /// Fraction of the current model load, 0…1. Only meaningful while
    /// `engineBusy()` is non-nil.
    var engineProgress: () -> Double = { 0 }
    /// (headline, isHealthy) — e.g. ("Listening · RTF 0.12", true)
    var statusLine: () -> (String, Bool) = { ("", true) }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // A status item whose button has neither image nor title renders as
            // zero-width — i.e. invisible, with no error. Always keep a textual
            // fallback so the item cannot silently vanish.
            if let image = NSImage(systemSymbolName: "captions.bubble",
                                   accessibilityDescription: "Subtitles") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "CC"
                FileHandle.standardError.write(
                    "status icon symbol unavailable; using text fallback\n".data(using: .utf8)!)
            }
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Reflect paused state in the menu bar itself, so the state is visible
    /// without opening anything.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let name = isPaused() ? "captions.bubble" : "captions.bubble.fill"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Subtitles") {
            image.isTemplate = true
            button.image = image
        }
        button.alphaValue = isPaused() ? 0.45 : 1.0
        if statusLine().1 { button.toolTip = nil }
    }

    /// Show or hide the red dot. Called on every status update from the core, so
    /// the badge appears without the user having to open the menu — the whole
    /// point of moving this out of the overlay.
    func updateHealthIndicator() {
        guard let button = statusItem.button else { return }

        // A load in flight outranks the health dot: the two would badge the same
        // corner, and "no audio reaching Subtitles" is not a useful thing to
        // shout while the recogniser demonstrably is not up yet.
        if let busy = engineBusy() {
            let since = busySince ?? Date()
            busySince = since
            button.toolTip = busy
            guard Date().timeIntervalSince(since) >= busyBadgeDelay else { return }
            if alertDot.superview != nil { alertDot.removeFromSuperview() }
            if busyDot.superview == nil { button.addSubview(busyDot) }
            busyDot.frame = badgeRect(in: button, size: 6)
            startPulse()
            return
        }
        busySince = nil
        if busyDot.superview != nil {
            busyDot.layer?.removeAnimation(forKey: "pulse")
            busyDot.removeFromSuperview()
        }

        let (_, healthy) = statusLine()
        if healthy {
            if alertDot.superview != nil { alertDot.removeFromSuperview() }
            return
        }
        if alertDot.superview == nil { button.addSubview(alertDot) }
        alertDot.frame = badgeRect(in: button, size: 6)
        button.toolTip = "No audio reaching Subtitles — check audio permission"
    }

    /// Top-right corner of the *glyph*, not the button. The button is wider and
    /// taller than the icon it draws, so positioning against its bounds parks the
    /// badge in the padding instead of on the icon.
    private func badgeRect(in button: NSStatusBarButton, size: CGFloat) -> NSRect {
        let glyph = button.image?.size ?? NSSize(width: 16, height: 16)
        let glyphRect = NSRect(x: (button.bounds.width - glyph.width) / 2,
                               y: (button.bounds.height - glyph.height) / 2,
                               width: glyph.width, height: glyph.height)
        let x = glyphRect.maxX - size + 1
        // NSStatusBarButton is not flipped, but do not assume it: getting this
        // wrong silently puts the badge on the opposite corner.
        let y = button.isFlipped ? glyphRect.minY - 1 : glyphRect.maxY - size + 1
        return NSRect(x: x, y: y, width: size, height: size)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        refreshIcon()
        updateHealthIndicator()
    }

    // A menu's contents are frozen for as long as it is open, so without this the
    // bar shows whatever percentage it happened to be at when the menu was pulled
    // down.
    //
    // Started from `rebuild()` rather than `menuWillOpen`: the item and the timer
    // that drives it then come from one place, and there is no ordering to get
    // wrong between the two delegate callbacks.
    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let busy = self.engineBusy() else {
                // Finished with the menu still open. The menu only rebuilds when
                // it is opened, so left alone the bar just sits there — a load
                // that visibly completed, parked at whatever percentage it last
                // reached. Swap it for the status line in place instead.
                self.finishProgressItem()
                return
            }
            self.progressView?.update(text: busy, fraction: self.engineProgress())
        }
        // Menu tracking runs the main run loop in `.eventTracking`, so name that
        // mode explicitly — `.common` alone was silent for exactly as long as the
        // menu was on screen, which is the only time this timer is worth having.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Retire the bar the moment the load finishes, swapping it for the status
    /// line at the same position.
    ///
    /// An open `NSMenu` can be mutated, so this replaces the one item rather than
    /// calling `rebuild()` — tearing every item out from under a menu the user is
    /// reading is a good way to make it flicker or close.
    private func finishProgressItem() {
        stopProgressTimer()
        defer {
            progressView = nil
            progressItem = nil
        }
        guard let item = progressItem, let index = menu.index(of: item) as Int?, index >= 0
        else { return }
        menu.removeItem(at: index)
        menu.insertItem(statusLineItem(), at: index)
    }

    private func statusLineItem() -> NSMenuItem {
        let (text, healthy) = statusLine()
        let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if !healthy {
            status.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: NSColor.systemRed])
        }
        return status
    }

    func menuDidClose(_ menu: NSMenu) { stopProgressTimer() }

    private func rebuild() {
        menu.removeAllItems()

        if let busy = engineBusy() {
            // A bar rather than the plain status line: the first-run download is
            // ~600 MB, and "42% (12/28 files)" is the difference between waiting
            // and wondering whether to force-quit.
            let view = ProgressMenuView()
            view.update(text: busy, fraction: engineProgress())
            let item = NSMenuItem()
            item.view = view
            item.isEnabled = false
            menu.addItem(item)
            progressView = view
            progressItem = item
            startProgressTimer()
        } else {
            progressView = nil
            progressItem = nil
            stopProgressTimer()
            menu.addItem(statusLineItem())
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: isPaused() ? "Resume Subtitles" : "Pause Subtitles",
            action: #selector(togglePause), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(sourceMenuItem())
        menu.addItem(modelMenuItem())
        menu.addItem(textSizeMenuItem())

        let vad = NSMenuItem(title: "Skip Non-Speech (VAD)",
                             action: #selector(toggleVAD), keyEquivalent: "")
        vad.target = self
        vad.state = vadEnabled() ? .on : .off
        vad.toolTip = "Stops music reaching the recogniser"
        menu.addItem(vad)

        let speakers = NSMenuItem(title: "New Box On Speaker Change",
                                  action: #selector(toggleSpeakerBreaks), keyEquivalent: "")
        speakers.target = self
        speakers.state = speakerBreaksEnabled() ? .on : .off
        speakers.toolTip = "Runs a second model on the Neural Engine"
        menu.addItem(speakers)

        let reset = NSMenuItem(title: "Reset Overlay Position",
                               action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(permissionMenuItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Subtitles", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: source

    private func sourceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Listen To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentSource()

        let all = NSMenuItem(title: "All system audio",
                             action: #selector(selectAllAudio), keyEquivalent: "")
        all.target = self
        all.state = current == .allSystemAudio ? .on : .off
        sub.addItem(all)

        let sources = SystemAudioTap.audioSources()
        let playing = sources.filter(\.isPlaying)
        let idle = sources.filter { !$0.isPlaying }

        if !playing.isEmpty {
            sub.addItem(.separator())
            let header = NSMenuItem(title: "Playing now", action: nil, keyEquivalent: "")
            header.isEnabled = false
            sub.addItem(header)
            for p in playing { sub.addItem(processItem(p, current: current, marker: " ●")) }
        }
        if !idle.isEmpty {
            sub.addItem(.separator())
            let header = NSMenuItem(title: "Other audio apps", action: nil, keyEquivalent: "")
            header.isEnabled = false
            sub.addItem(header)
            // Long tail of helpers and daemons; showing all of them is noise.
            for p in idle.prefix(12) { sub.addItem(processItem(p, current: current, marker: "")) }
        }

        item.submenu = sub
        return item
    }

    private func processItem(_ p: AudioSourceEntry, current: AudioSource,
                             marker: String) -> NSMenuItem {
        // Show the process count for families with helpers, so it is clear the
        // selection covers "Chrome and its 3 helpers", not one process.
        let suffix = p.pids.count > 1 ? " (\(p.pids.count))" : ""
        let item = NSMenuItem(title: p.name + suffix + marker,
                              action: #selector(selectProcess(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = p
        if case let .app(id, _) = current, id == p.id { item.state = .on }
        return item
    }

    @objc private func selectAllAudio() { onSelectSource?(.allSystemAudio) }

    @objc private func selectProcess(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? AudioSourceEntry else { return }
        onSelectSource?(.app(id: p.id, name: p.name))
    }

    // MARK: model

    private func modelMenuItem() -> NSMenuItem {
        // The picker stays put and stays live during a load. `applyVariant`
        // already ignores a switch while one is in flight, and the progress bar
        // above says why — so neither replacing the submenu nor greying it out
        // buys anything the user cannot already see.
        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentVariantID()

        // Every variant is Parakeet on the Neural Engine; they differ in chunk
        // size, which is the latency/accuracy dial worth exposing.
        for variant in FluidVariant.allCases {
            // The multilingual entry is a submenu instead of a plain choice:
            // picking it without saying which language is not a complete request,
            // and the language decides which pack gets downloaded.
            if variant.isMultilingual {
                sub.addItem(.separator())
                sub.addItem(languageMenuItem(selected: variant.rawValue == current))
                continue
            }
            let entry = NSMenuItem(title: variant.displayName,
                                   action: #selector(selectVariant(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = variant.rawValue
            entry.state = variant.rawValue == current ? .on : .off
            entry.attributedTitle = NSAttributedString(
                string: "\(variant.displayName)\n\(variant.note)",
                attributes: [.font: NSFont.menuFont(ofSize: 0)])
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    /// The multilingual model, with its language as the actual choice.
    ///
    /// Selecting a language selects the model too — one click for the whole
    /// intent, and no way to end up with a language set that the running model
    /// cannot honour. The parent carries the current language so the state reads
    /// without opening the third level.
    private func languageMenuItem(selected: Bool) -> NSMenuItem {
        let current = currentLanguageID()
        let language = FluidLanguage(rawValue: current) ?? .auto
        let variant = FluidVariant.multilingual
        let title = selected
            ? "\(variant.displayName) · \(language.displayName)"
            : variant.displayName
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: "\(title)\n\(variant.note)",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        item.state = selected ? .on : .off

        let sub = NSMenu()
        for lang in FluidLanguage.allCases {
            // The Latin-script six share one download; auto and zh/ja need the
            // bigger pack. Separated so the boundary that costs a download is at
            // least visible.
            if lang == .en || lang == .zh { sub.addItem(.separator()) }
            let entry = NSMenuItem(title: lang.displayName,
                                   action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = lang.rawValue
            entry.state = (selected && lang.rawValue == current) ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = FluidLanguage(rawValue: raw) else { return }
        onSelectLanguage?(lang)
    }

    @objc private func selectVariant(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let variant = FluidVariant(rawValue: raw) else { return }
        onSelectVariant?(variant)
    }

    // MARK: text size

    private func textSizeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentFontSize()
        for (label, size) in [("Small", CGFloat(22)), ("Medium", 30), ("Large", 40), ("Huge", 52)] {
            let entry = NSMenuItem(title: label, action: #selector(selectSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size
            entry.state = abs(size - current) < 0.5 ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        onFontSize?(size)
    }

    // MARK: permission

    private func permissionMenuItem() -> NSMenuItem {
        let (_, healthy) = statusLine()
        if healthy {
            let ok = NSMenuItem(title: "Audio access: OK", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            return ok
        }
        let item = NSMenuItem(title: "Fix audio permission…",
                              action: #selector(openPrivacySettings), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPrivacySettings() {
        // No documented anchor for the audio-recording pane specifically, so open
        // Privacy & Security and let the user pick.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: actions

    @objc private func togglePause() { onTogglePause?(); refreshIcon() }
    @objc private func toggleVAD() { onToggleVAD?() }
    @objc private func toggleSpeakerBreaks() { onToggleSpeakerBreaks?() }
    @objc private func resetPosition() { onResetPosition?() }
    @objc private func quit() { onQuit?() }
}

// MARK: - Progress item

/// The headline and bar shown in place of the status line while a model loads.
///
/// A custom view rather than two menu items: `NSMenuItem` has no progress bar,
/// and a text-only percentage in a disabled item is easy to mistake for a stuck
/// app on a download this long.
final class ProgressMenuView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        // Matches the width AppKit gives a typical menu; the menu sizes itself to
        // the widest item, so this sets the floor rather than fighting anything.
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))

        label.font = .menuFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 20, y: 24, width: 244, height: 16)
        addSubview(label)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.frame = NSRect(x: 20, y: 8, width: 244, height: 12)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, fraction: Double) {
        label.stringValue = text
        bar.doubleValue = fraction
        // Paint synchronously. Marking the view dirty defers the redraw to the
        // run loop's display cycle, which an open menu is not reliably running —
        // the values updated underneath while the pixels stayed put.
        displayIfNeeded()
    }
}
