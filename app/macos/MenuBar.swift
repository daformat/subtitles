// Status bar item — the app's only chrome.
//
// The app is LSUIElement (no Dock icon, no menu bar of its own), so this is where
// everything the user can change lives: what to listen to, text size, overlay
// position, permission state, and quit.
//
// The source submenu is rebuilt every time the menu opens, because "which apps
// are playing audio right now" is exactly the kind of thing that is stale a second
// after you cache it.

import CSubs
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

    // Wired up by main.swift.
    var onTogglePause: (() -> Void)?
    var onSelectSource: ((AudioSource) -> Void)?
    var onSelectModel: ((ModelSpec) -> Void)?
    var onSelectFluid: ((FluidVariant) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?
    var onResetPosition: (() -> Void)?
    var onQuit: (() -> Void)?

    var isPaused: () -> Bool = { false }
    var currentSource: () -> AudioSource = { .allSystemAudio }
    var currentFontSize: () -> CGFloat = { 30 }
    var currentModelID: () -> String = { "" }
    var currentFluidID: () -> String = { "" }
    /// Non-nil while a model is downloading or loading; disables the picker.
    var modelBusy: () -> String? = { nil }
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
        let (_, healthy) = statusLine()
        if healthy {
            if alertDot.superview != nil { alertDot.removeFromSuperview() }
            return
        }
        if alertDot.superview == nil { button.addSubview(alertDot) }

        // Badge the glyph's top-right corner, not the button's. The button is
        // wider and taller than the icon it draws, so positioning against its
        // bounds parks the dot in the padding instead of on the icon.
        let size: CGFloat = 6
        let glyph = button.image?.size ?? NSSize(width: 16, height: 16)
        let glyphRect = NSRect(x: (button.bounds.width - glyph.width) / 2,
                               y: (button.bounds.height - glyph.height) / 2,
                               width: glyph.width, height: glyph.height)
        let x = glyphRect.maxX - size + 1
        // NSStatusBarButton is not flipped, but do not assume it: getting this
        // wrong silently puts the badge on the opposite corner.
        let y = button.isFlipped ? glyphRect.minY - 1 : glyphRect.maxY - size + 1
        alertDot.frame = NSRect(x: x, y: y, width: size, height: size)
        button.toolTip = "No audio reaching Subtitles — check audio permission"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        refreshIcon()
        updateHealthIndicator()
    }

    private func rebuild() {
        menu.removeAllItems()

        let (text, healthy) = statusLine()
        let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if !healthy {
            status.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: NSColor.systemRed])
        }
        menu.addItem(status)
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
        // While a model is downloading or loading, replace the picker with its
        // progress rather than letting a second switch be started underneath it.
        if let busy = modelBusy() {
            let item = NSMenuItem(title: busy, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = currentModelID()

        for spec in ModelCatalog.all {
            let installed = ModelCatalog.isInstalled(spec)
            let entry = NSMenuItem(title: spec.name,
                                   action: #selector(selectModel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = spec
            entry.state = spec.id == current ? .on : .off
            // Measured numbers, plus the download size when it is not yet local —
            // the two things you actually need to choose between them.
            let detail = installed ? spec.note : "\(spec.note) · \(spec.sizeMB) MB download"
            entry.attributedTitle = NSAttributedString(
                string: "\(spec.name)\n\(detail)",
                attributes: [.font: NSFont.menuFont(ofSize: 0)])
            sub.addItem(entry)
        }
        // FluidAudio runs Parakeet on the Neural Engine. Separate section
        // because it is a different engine, not just a different checkpoint:
        // it punctuates and cases its own output, and the core stops
        // transcribing entirely.
        sub.addItem(.separator())
        let header = NSMenuItem(title: "FluidAudio · Apple Neural Engine",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)

        let currentFluid = currentFluidID()
        for variant in FluidVariant.allCases {
            let entry = NSMenuItem(title: variant.displayName,
                                   action: #selector(selectFluid(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = variant.rawValue
            entry.state = variant.rawValue == currentFluid ? .on : .off
            entry.attributedTitle = NSAttributedString(
                string: "\(variant.displayName)\n\(variant.note)",
                attributes: [.font: NSFont.menuFont(ofSize: 0)])
            sub.addItem(entry)
        }

        item.submenu = sub
        return item
    }

    @objc private func selectFluid(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let variant = FluidVariant(rawValue: raw) else { return }
        onSelectFluid?(variant)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ModelSpec else { return }
        onSelectModel?(spec)
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
    @objc private func resetPosition() { onResetPosition?() }
    @objc private func quit() { onQuit?() }
}
