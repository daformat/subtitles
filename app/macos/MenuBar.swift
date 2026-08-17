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

/// How loudly the status line is speaking.
///
/// A bool was not enough once "nothing is playing" stopped being a fault. Idle is
/// the common case — the app sits waiting all day — and dressing it as an error
/// trains the user to ignore the one state that is genuinely worth reading.
enum StatusSeverity {
    /// Working normally.
    case normal
    /// Nothing to do: paused, or no audio playing anywhere. Not a problem.
    case idle
    /// Something is actually wrong and the user may need to act.
    case warning
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// What the badge on the icon is saying.
    ///
    /// One dot with four states rather than a view per state: they are mutually
    /// exclusive by definition — all four badge the same corner — and separate
    /// views meant hand-written code to make sure two never showed at once.
    private enum Badge: Equatable {
        /// Paused, or nothing worth saying.
        case none
        /// A model is downloading or loading.
        case loading
        /// Capturing, and audio is arriving.
        case live
        /// Capturing, but only digital silence is arriving.
        case warning

        var colour: NSColor {
            switch self {
            // Indigo — the blue-purple Control Center uses — and deliberately not
            // red. Red means recording, and this app never records: audio is
            // transcribed as it passes and nothing is written anywhere. Orange and
            // green are out too, being the system's microphone and camera
            // indicators.
            //
            // It is the closest of the candidates to the loading blue (#5856D6
            // against #007AFF), which is tolerable only because a load is brief
            // and this is the steady state — the two are rarely on screen near
            // each other in time.
            case .live: return .systemIndigo
            // Yellow for the one condition that is unambiguously wrong and
            // reliably detectable. Not red — in a menu bar that says recording,
            // which this app never does — and not orange or green, which macOS
            // uses for microphone and camera in use.
            case .warning: return .systemYellow
            case .loading: return .systemBlue
            case .none: return .clear
            }
        }

        /// Seconds per pulse, or nil to sit still. A warning is not in progress,
        /// so it does not move; loading is brisker than listening, because one is
        /// working through something finite and the other is a steady state you
        /// may watch all day.
        var pulse: TimeInterval? {
            switch self {
            case .loading: return 0.7
            case .live: return 1.8
            case .warning, .none: return nil
            }
        }
    }

    /// Badge, drawn as a subview rather than composited into the icon.
    /// Compositing would force `isTemplate = false`, and the icon would then stop
    /// adapting to light/dark menu bars; a subview keeps the template intact.
    ///
    /// A dot rather than an `NSProgressIndicator` for the loading case: at 6pt a
    /// spinner renders as an illegible grey smudge against the menu bar, while a
    /// pulse reads as "working" at any size.
    private lazy var badgeDot: NSView = {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        return dot
    }()

    private var badge: Badge = .none

    private func setBadge(_ next: Badge, in button: NSStatusBarButton) {
        defer {
            // Always re-place it: the button's bounds change with the icon.
            if next != .none { badgeDot.frame = badgeRect(in: button, size: 6) }
        }
        guard next != badge else { return }
        badge = next

        guard next != .none else {
            badgeDot.layer?.removeAnimation(forKey: "pulse")
            badgeDot.removeFromSuperview()
            return
        }
        badgeDot.layer?.backgroundColor = next.colour.cgColor
        if badgeDot.superview == nil { button.addSubview(badgeDot) }

        badgeDot.layer?.removeAnimation(forKey: "pulse")
        guard let duration = next.pulse else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.25
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        badgeDot.layer?.add(animation, forKey: "pulse")
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
    var onToggleReveal: (() -> Void)?
    var revealEnabled: () -> Bool = { true }
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
    /// (headline, how loudly to say it) — e.g. ("Nemotron · 560 ms · RTF 0.12", .normal)
    var statusLine: () -> (String, StatusSeverity) = { ("", .normal) }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // A status item whose button has neither image nor title renders as
            // zero-width — i.e. invisible, with no error. Always keep a textual
            // fallback so the item cannot silently vanish.
            if let image = Self.statusIcon() {
                button.image = image
            } else {
                button.title = "CC"
                FileHandle.standardError.write(
                    "status icon unavailable; using text fallback\n".data(using: .utf8)!)
            }
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The bundled caption-bubble mark, falling back to the SF Symbol.
    ///
    /// `NSImage` reads SVG directly (macOS 13+, `_NSSVGImageRep`), so the file
    /// ships as-is with no conversion step. `isTemplate` is what matters: it
    /// makes AppKit use the alpha channel only and tint to suit a light or dark
    /// menu bar, which is why the fill colour in the file is irrelevant.
    ///
    /// The fallback is not decoration — a binary run straight from `.build` has
    /// no bundle to read the file out of.
    private static func statusIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.accessibilityDescription = "Subtitles"
            return image
        }
        guard let image = NSImage(systemSymbolName: "captions.bubble",
                                  accessibilityDescription: "Subtitles") else { return nil }
        image.isTemplate = true
        return image
    }

    /// Reflect paused state in the menu bar itself, so the state is visible
    /// without opening anything.
    ///
    /// Dimming only. The icon used to swap between the outline and filled SF
    /// Symbols, which the custom mark has no counterpart for — and the dimming
    /// was carrying that signal anyway.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.alphaValue = isPaused() ? 0.45 : 1.0
        // Tooltip deliberately not touched here: `updateHealthIndicator` sets it
        // on every branch, and two owners meant it depended on call order.
    }

    /// Show or hide the warning dot. Called on every status update from the core, so
    /// the badge appears without the user having to open the menu — the whole
    /// point of moving this out of the overlay.
    func updateHealthIndicator() {
        guard let button = statusItem.button else { return }
        // Dimming belongs to every refresh, not just to opening the menu. The
        // ⌥⌘S hotkey calls straight through to the app's togglePause, so this is
        // the only thing that tells the menu bar a pause happened — and pausing
        // stops the tap, which stops the status events that used to drive it.
        refreshIcon()

        // A load in flight outranks everything else: it badges the same corner,
        // and neither "listening" nor "no audio reaching Subtitles" is a useful
        // thing to claim while the recogniser demonstrably is not up yet.
        if let busy = engineBusy() {
            let since = busySince ?? Date()
            busySince = since
            button.toolTip = busy
            // Below the delay the load is too short to be worth announcing, so
            // hold whatever was showing rather than flashing a badge on and off.
            guard Date().timeIntervalSince(since) >= busyBadgeDelay else { return }
            setBadge(.loading, in: button)
            return
        }
        busySince = nil

        // Paused is the deliberate absence of capture, so it says nothing at all —
        // the dimmed icon is the signal. A live badge here would claim the app is
        // listening when it has just been told to stop.
        if isPaused() {
            button.toolTip = nil
            setBadge(.none, in: button)
            return
        }

        // Idle shows nothing rather than a dot: waiting for something to play is
        // the resting state, and a badge for it would be lit most of the day.
        let (text, severity) = statusLine()
        button.toolTip = severity == .warning ? text : nil
        switch severity {
        case .normal: setBadge(.live, in: button)
        case .idle: setBadge(.none, in: button)
        case .warning: setBadge(.warning, in: button)
        }
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
        let (text, severity) = statusLine()
        let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        status.isEnabled = false
        // Idle is greyed rather than left in the default colour: it reads as
        // "nothing to report", which is exactly what it means.
        let colour: NSColor? = switch severity {
        case .normal: nil
        case .idle: .secondaryLabelColor
        case .warning: .systemRed
        }
        if let colour {
            status.attributedTitle = NSAttributedString(
                string: text, attributes: [.foregroundColor: colour])
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

        let reveal = NSMenuItem(title: "Fade Away Under Pointer",
                                action: #selector(toggleReveal), keyEquivalent: "")
        reveal.target = self
        reveal.state = revealEnabled() ? .on : .off
        reveal.toolTip = "Point at the box to see through it; hold ⇧ to keep it solid"
        menu.addItem(reveal)

        let reset = NSMenuItem(title: "Reset Overlay Position",
                               action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(permissionMenuItem())
        menu.addItem(.separator())
        menu.addItem(welcomeMenuItem())
        menu.addItem(aboutMenuItem())
        menu.addItem(acknowledgementsMenuItem())
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
        let item = NSMenuItem(title: "Language / Models", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentVariantID()
        let onMultilingual = current == FluidVariant.multilingual.rawValue
        let language = FluidLanguage(rawValue: currentLanguageID()) ?? .auto

        // Language is the top level, because it is the first decision and for most
        // people the only one. Auto-detect leads as the default; English is the one
        // language with a choice of models behind it, the other seven being served
        // by the multilingual checkpoint alone.
        sub.addItem(autoDetectItem(checked: onMultilingual && language == .auto))

        // English stands apart from both packs: choosing it loads an English-only
        // checkpoint, not the multilingual model, so neither pack header applies
        // to it and its sizes live on its own entries.
        sub.addItem(.separator())
        sub.addItem(englishMenuItem(current: current))

        // Grouped by the download each one triggers, with the size named. Moving
        // within a group is instant; crossing between them is another ~600 MB, and
        // that is worth knowing before clicking rather than after.
        sub.addItem(.separator())
        sub.addItem(groupHeader("Latin-script pack · 583 MB"))
        for entry in [FluidLanguage.es, .fr, .it, .pt, .de] {
            sub.addItem(languageItem(entry, checked: onMultilingual && language == entry))
        }
        sub.addItem(.separator())
        sub.addItem(groupHeader("Full vocabulary · 633 MB"))
        for entry in [FluidLanguage.zh, .ja] {
            sub.addItem(languageItem(entry, checked: onMultilingual && language == entry))
        }

        item.submenu = sub
        return item
    }

    private func autoDetectItem(checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Multilingual",
                              action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = FluidLanguage.auto.rawValue
        item.state = checked ? .on : .off
        item.attributedTitle = NSAttributedString(
            string: "Multilingual\n633 MB · default · detects the language itself",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        return item
    }

    /// A disabled label over a group, matching the "Playing now" headers the
    /// source picker already uses.
    private func groupHeader(_ title: String) -> NSMenuItem {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        return header
    }

    private func languageItem(_ language: FluidLanguage, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: language.displayName,
                              action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = language.rawValue
        item.state = checked ? .on : .off
        return item
    }

    /// The English-only variants, behind one entry.
    ///
    /// Seven of the eight models are English checkpoints, and listing them flat
    /// meant seven lines each opening with the same word. A submenu says it once
    /// and leaves the entries free to be about what actually separates them —
    /// chunk size, which is the latency/accuracy dial this whole app is an
    /// argument about.
    private func englishMenuItem(current: String) -> NSMenuItem {
        // Nemotron first: it punctuates, it is the fastest tier on offer, and it
        // is what someone picking an English model most likely wants. The Parakeet
        // family follows — the EOU tiers, which emit no punctuation at all, then
        // Unified, which costs 2 s of latency for nothing Nemotron lacks.
        let variants: [FluidVariant] = [
            .nemotron560, .nemotron1120, .nemotron2240,
            .eou320, .eou1280, .eou160,
            .unified,
        ]
        let selected = variants.first { $0.rawValue == current }
        let item = NSMenuItem(
            title: selected.map { "English · \($0.displayName)" } ?? "English",
            action: nil, keyEquivalent: "")
        item.state = selected == nil ? .off : .on

        let sub = NSMenu()
        for variant in variants {
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

    /// Always present, never conditional.
    ///
    /// There is no API for "is audio capture granted" — a denied grant is
    /// indistinguishable from silence, which is the whole of §8b Finding 1. Every
    /// attempt to infer it has been wrong in one direction or the other: the old
    /// "Audio access: OK" asserted a grant that had never been demonstrated, often
    /// before a single sample had arrived, while "Fix audio permission…" appeared
    /// on a heuristic that misfired at launch about one start in four.
    ///
    /// A permanent entry claims nothing and is there whenever it is wanted, which
    /// is the honest shape for a question the app cannot answer.
    private func permissionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check Audio Permission…",
                              action: #selector(openPrivacySettings), keyEquivalent: "")
        item.target = self
        return item
    }

    private func welcomeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Show Welcome Screen Again",
                              action: #selector(showWelcome), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showWelcome() { WelcomeWindow.shared.show() }

    private func aboutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "About Subtitles",
                              action: #selector(showAbout), keyEquivalent: "")
        item.target = self
        return item
    }

    /// The window lives in About.swift: it carries a webview showing the
    /// site's demo, which the standard About panel has nowhere to put.
    @objc private func showAbout() { AboutWindow.shared.show() }

    /// Opens the notices file `build.sh` puts in the bundle.
    ///
    /// Apache-2.0 is satisfied by the file being *in* the bundle; this only makes
    /// it findable, which is worth one menu item and no window. Hidden when the
    /// file is absent rather than offering a dead item — a dev build run straight
    /// from `.build` has no bundle around it.
    private func acknowledgementsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Acknowledgements…",
                              action: #selector(openAcknowledgements), keyEquivalent: "")
        item.target = self
        item.isHidden = Self.noticesURL == nil
        return item
    }

    private static var noticesURL: URL? {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES",
                                        withExtension: "txt") else { return nil }
        return url
    }

    @objc private func openAcknowledgements() {
        guard let url = Self.noticesURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPrivacySettings() {
        // No documented anchor for the audio-recording pane specifically, so open
        // Privacy & Security and let the user pick.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: actions

    @objc private func togglePause() { onTogglePause?() }
    @objc private func toggleVAD() { onToggleVAD?() }
    @objc private func toggleReveal() { onToggleReveal?() }
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
        // Below zero means "working, length unknown" — see FluidAudioEngine's
        // `indeterminate`. Switching the style rather than parking the bar at
        // 100%, which reads as finished-and-stuck.
        let unknown = fraction < 0
        if unknown != bar.isIndeterminate {
            bar.isIndeterminate = unknown
            if unknown { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        }
        if !unknown { bar.doubleValue = fraction }
        // Paint synchronously. Marking the view dirty defers the redraw to the
        // run loop's display cycle, which an open menu is not reliably running —
        // the values updated underneath while the pixels stayed put.
        displayIfNeeded()
    }
}
