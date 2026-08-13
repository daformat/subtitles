// Phase 2 — the subtitle overlay.
//
// A borderless, click-through, never-focused panel that floats above everything
// including fullscreen apps. All the behaviour that made native the right call in
// PLAN.md §1 lives in this file: in Electron each of these is a flag that half
// works and regresses between versions.
//
// Interaction model: click-through by default, so the overlay never intercepts a
// click meant for the app underneath. Hold ⇧ to make it grabbable and drag it
// somewhere else; the position is remembered. ⇧ rather than ⌥ because holding ⌥
// while dragging a window puts macOS into its tiling preview, which fights the
// drag.
//
// ⇧ is detected by polling `NSEvent.modifierFlags` rather than installing a
// global event monitor — a keyboard monitor would demand Accessibility
// permission, and asking for a second scary prompt to enable dragging is a bad
// trade.

import CSubs
import AppKit

// MARK: - Panel

final class SubtitlePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel is what stops the overlay from stealing focus
            // from whatever the user is actually working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // Follow the user across Spaces and sit above fullscreen apps rather than
        // being left behind on one desktop.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // Never become key or main: taking focus would pull the caret out of the
    // user's editor every time a subtitle appeared.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

final class SubtitleView: NSView {
    var committed = "" { didSet { needsDisplay = true } }
    var tentative = "" { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 30 { didSet { needsDisplay = true } }

    /// Hard ceiling on displayed lines. The controller pages the text so this is
    /// never actually exceeded; the view clips as a last resort.
    var maxLines = 3

    private let inset = NSSize(width: 22, height: 14)
    private let corner: CGFloat = 14

    private var font: NSFont {
        // A rounded, heavy face reads better at a glance against arbitrary video.
        let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: fontSize) ?? base
    }

    private func paragraph(centered: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        // Measured left-aligned, drawn centred. A centred line fragment spans the
        // whole container, so measuring it reports the ceiling width rather than
        // the width the glyphs actually need.
        p.alignment = centered ? .center : .left
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return p
    }

    /// Committed text at full strength, the in-flight tail dimmed.
    ///
    /// Spike 0A measured this engine as effectively non-revising (0 ms p50 commit
    /// lag, 4 of 66 words ever revised), so in practice the dimmed tail is usually
    /// empty. It stays because it costs nothing and is what makes a revising
    /// engine survivable if the model is ever swapped.
    func attributed(committed: String, tentative: String,
                    centered: Bool = true) -> NSAttributedString {
        let style = paragraph(centered: centered)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: committed, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]))
        out.append(NSAttributedString(string: tentative, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .paragraphStyle: style,
        ]))
        return out
    }

    private func textWidth(for width: CGFloat) -> CGFloat { width - inset.width * 2 }

    /// Exact text extent and wrapped line count, from the real layout engine.
    ///
    /// `boundingRect` under-reports width by enough to clip the last word, and
    /// dividing its height by a nominal line height is off-by-one near the
    /// boundary — either error shows up directly as clipped or mis-paged text.
    private func metrics(committed: String, tentative: String,
                         maxWidth: CGFloat) -> (used: NSSize, lines: Int) {
        let text = attributed(committed: committed, tentative: tentative, centered: false)
        guard text.length > 0 else { return (.zero, 0) }

        let container = NSTextContainer(
            size: CGSize(width: textWidth(for: maxWidth), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        let storage = NSTextStorage(attributedString: text)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var lines = 0
        var index = 0
        var widest: CGFloat = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            let used = manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            widest = max(widest, used.width)
            index = NSMaxRange(range)
            lines += 1
        }
        let height = manager.usedRect(for: container).height
        return (NSSize(width: ceil(widest), height: ceil(height)), lines)
    }

    func lineCount(committed: String, tentative: String, width: CGFloat) -> Int {
        metrics(committed: committed, tentative: tentative, maxWidth: width).lines
    }

    /// Size the box needs, hugging its content.
    ///
    /// `maxWidth` is a ceiling, not the width: a short line gets a short box.
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let m = metrics(committed: committed, tentative: tentative, maxWidth: maxWidth)
        guard m.lines > 0 else { return .zero }

        let lineHeight = font.ascender - font.descender + font.leading + 2
        let cappedHeight = min(m.used.height, lineHeight * CGFloat(maxLines) + 4)

        // +2 of slack so a fractional advance never clips the final glyph.
        let hugging = m.used.width + 2 + inset.width * 2
        // A floor stops one- or two-character updates producing a jittering pill.
        let width = min(max(hugging, 140), maxWidth)
        return NSSize(width: width, height: ceil(cappedHeight) + inset.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributed(committed: committed, tentative: tentative)
        guard text.length > 0 else { return }

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).fill()

        text.draw(with: bounds.insetBy(dx: inset.width, dy: inset.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - Controller

final class OverlayController {
    private let panel: SubtitlePanel
    private let view: SubtitleView
    private var idleTimer: Timer?
    private var modifierTimer: Timer?
    private var moveObserver: NSObjectProtocol?
    /// True only while `layout()` is moving the panel itself, so the move
    /// observer can tell our repositioning apart from the user's dragging.
    private var isRepositioning = false

    // Fade on *text* inactivity, not audio inactivity.
    //
    // Audio-driven fading fails on the case that matters most: music. A backing
    // track keeps the voice gate open indefinitely, so the endpoint never fires
    // and the last thing anyone said stays frozen on screen over the music. What
    // the reader cares about is whether new words are arriving, not whether the
    // room is quiet.
    private var lastTextAt = Date.distantPast
    private var lastShownText = ""
    private let textIdleTimeout: TimeInterval = 4
    private var isDraggable = false

    /// Paused. Nothing may put the overlay back on screen until resumed — not
    /// words already in the engine's pipeline when the pause landed, not the ⇧
    /// drag nudge.
    ///
    /// A flag rather than a one-shot `clearAndHide()`: pausing gates audio at the
    /// tap, but whatever is already inside the ring and the recogniser keeps
    /// arriving for a beat afterwards, and each update called `show()` and put the
    /// box straight back up.
    private var isSuppressed = false

    // ── paging state ──
    // Broadcast subtitles never scroll a wall of text: they fill, clear, and
    // start again. `page` is what is on screen now; when the next words would
    // push past maxLines we drop the page entirely and begin a new one from
    // those words, rather than letting old text slide up out of view.
    private var page = ""
    private var pendingCommit = ""
    private var tentative = ""
    private var startFreshOnNextText = false
    /// Audio time the current page starts at. Words spoken before this are on a
    /// page the reader has already lost.
    ///
    /// A *time* anchor rather than a word index: a word-count anchor skips any
    /// words that arrive in the same update as the anchor point, which is why a
    /// new page could previously start part-way into a sentence.
    private var pageStartTime: TimeInterval = 0
    /// Latest word end seen, so "start fresh" means "from here on in the audio".
    private var latestWordEnd: TimeInterval = 0

    /// Fired once the overlay has faded because no new text arrived. The engine
    /// uses it to drop a context that may be full of music.
    var onFaded: (() -> Void)?

    /// Remembered across launches once the user drags the panel somewhere.
    ///
    /// Stored as (centre x, bottom y) rather than the frame origin: the box now
    /// resizes with its text, and anchoring the origin would make it grow
    /// rightwards off its position instead of expanding evenly about its centre.
    private static let anchorKey = "overlay.anchor"

    /// Where the box sits, and the *only* source of truth for it while running —
    /// `UserDefaults` is persistence, read once here and written on release.
    /// `layout()` used to re-read the defaults on every text update, so a word
    /// arriving mid-drag snapped the panel back to the last saved position.
    ///
    /// nil until the user drags: the fallback is derived from the screen on every
    /// layout, so an untouched overlay follows a resolution or display change.
    private var anchor: NSPoint?

    private var maxWidth: CGFloat {
        guard let screen = NSScreen.main else { return 900 }
        return min(screen.frame.width * 0.7, 1100)
    }

    init(fontSize: CGFloat) {
        let initial = NSRect(x: 0, y: 0, width: 900, height: 80)
        panel = SubtitlePanel(contentRect: initial)
        view = SubtitleView(frame: initial)
        view.fontSize = fontSize
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let saved = UserDefaults.standard.string(forKey: Self.anchorKey) {
            anchor = NSPointFromString(saved)
        }

        // While the user drags, the panel's own position is the truth — this is
        // what feeds it back into `anchor` so the next word lays out where the box
        // now is.
        //
        // `queue: nil` on purpose: the block then runs synchronously inside the
        // posting call, so `isRepositioning` is still true for the moves layout()
        // makes itself. Re-deriving the anchor from a frame we just computed would
        // creep it half a pixel sideways on every word, because the origin is
        // rounded and half a text width is not.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            guard let self, !self.isRepositioning else { return }
            self.anchor = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.minY)
        }

        // Polled rather than armed per update: a one-shot timer must be cancelled
        // and re-armed on every text change, and anything that forgets to re-arm
        // strands the overlay on screen — which is exactly the bug this replaces.
        // A poll cannot be forgotten.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.fadeIfTextIdle()
        }

        // ⇧ toggles grabbable. Polled, not monitored — see the file header.
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Not while paused: the panel is invisible then, and making an
            // invisible panel grabbable just means it swallows clicks meant for
            // whatever is underneath.
            let wantsDrag = NSEvent.modifierFlags.contains(.shift) && !self.isSuppressed
            if wantsDrag != self.isDraggable {
                self.isDraggable = wantsDrag
                self.panel.ignoresMouseEvents = !wantsDrag
                // Nudge visible while it can be grabbed, so it is obvious the
                // overlay is now catching clicks instead of passing them through.
                if wantsDrag { self.panel.alphaValue = 1.0 }
                if !wantsDrag { self.saveAnchor() }
            }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        idleTimer?.invalidate()
        modifierTimer?.invalidate()
    }

    // MARK: text

    /// Committed text arrives as a delta and does *not* render on its own — the
    /// core always follows a COMMITTED with a TENTATIVE, and rendering on both
    /// would paint the new word beside a stale tail for one frame.
    func appendCommitted(_ delta: String) {
        pendingCommit += delta
    }

    func setTentative(_ text: String) {
        tentative = text
        if startFreshOnNextText, !(pendingCommit.isEmpty && text.isEmpty) {
            startFreshOnNextText = false
            page = ""
        }

        let grown = page + pendingCommit
        if !page.isEmpty,
           view.lineCount(committed: grown, tentative: text, width: maxWidth) > view.maxLines {
            // Would overflow: clear and restart from the words that caused it, so
            // nothing is lost and nothing scrolls.
            page = trimLeadingSpace(pendingCommit)
        } else {
            page = grown
        }
        pendingCommit = ""

        view.committed = page
        view.tentative = tentative
        layout()
        show()
    }

    /// Render the transcript, paged by audio time.
    ///
    /// Fills to `maxLines`, then clears and restarts from the first word that did
    /// not fit — the same behaviour as broadcast subtitles, which never scroll.
    func showWords(_ words: [TimedWord]) {
        guard !isSuppressed else { return }
        guard let newest = words.last else { return }

        // Time running backwards means the engine restarted its transcript
        // (finish/reset), so the old anchor refers to audio that no longer exists.
        if newest.end < latestWordEnd {
            pageStartTime = 0
            latestWordEnd = 0
        }

        if startFreshOnNextText {
            startFreshOnNextText = false
            if ProcessInfo.processInfo.environment["SUBS_DEBUG_PAGING"] != nil {
                let first = words.first.map { "\($0.text)@\(String(format: "%.2f", $0.start))" } ?? "-"
                let msg = "[page] fresh: anchor=\(String(format: "%.2f", latestWordEnd)) "
                    + "words=\(words.count) first=\(first) "
                    + "newest=\(newest.text)@\(String(format: "%.2f", newest.end))\n"
                FileHandle.standardError.write(msg.data(using: .utf8)!)
            }
            // Everything already spoken belongs to the page just closed; the new
            // one begins with whatever comes after it. Anchoring on *time* is what
            // stops words arriving in this same update from being skipped.
            pageStartTime = latestWordEnd
        }
        latestWordEnd = max(latestWordEnd, newest.end)

        var visible = words.filter { $0.start >= pageStartTime }
        if ProcessInfo.processInfo.environment["SUBS_DEBUG_PAGING"] != nil, !words.isEmpty {
            let msg = "[page] anchor=\(String(format: "%.2f", pageStartTime)) "
                + "total=\(words.count) visible=\(visible.count) "
                + "firstVisible=\(visible.first?.text ?? "-")\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
        guard !visible.isEmpty else { return }

        // Advance the page while the visible text overflows.
        while true {
            let fitted = longestFittingPrefix(visible.map(\.text), from: 0)
            if fitted >= visible.count { break }   // it all fits
            if fitted <= 0 { break }               // one word wider than the box
            pageStartTime = visible[fitted].start  // new page starts where it spilled
            visible = Array(visible[fitted...])
        }

        let text = visible.map(\.text).joined(separator: " ")

        // An unchanged transcript is not new information: return before touching
        // visibility at all.
        //
        // Testing `alphaValue == 0` here instead was not enough. Engines resend
        // identical partials several times a second; mid-fade the alpha is
        // somewhere between 0 and 1, so the guard missed, `show()` animated it
        // back to full, and the idle poll faded it again — the overlay flashed.
        // Worse, `show()` interrupting the fade meant its completion handler kept
        // seeing a non-zero alpha and never cleared the page, so the next speaker
        // appended to text that should long since have gone.
        guard text != lastShownText else { return }
        lastShownText = text
        lastTextAt = Date()

        page = text
        pendingCommit = ""
        tentative = ""
        view.committed = page
        view.tentative = ""
        layout()
        show()
    }

    /// Index one past the last word that still fits within `maxLines`.
    private func longestFittingPrefix(_ words: [String], from start: Int) -> Int {
        var end = start
        while end < words.count {
            let candidate = words[start...end].joined(separator: " ")
            if view.lineCount(committed: candidate, tentative: "", width: maxWidth) > view.maxLines {
                return end
            }
            end += 1
        }
        return words.count
    }

    /// Speech stopped briefly. Whatever is on screen stays there, but the next
    /// words start a new page instead of being appended to it — so pages break at
    /// natural pauses rather than wherever the text happened to overflow.
    ///
    /// Display-only: the core keeps the recognizer running across this, so there
    /// is no accuracy cost (unlike an endpoint, which resets it).
    func markPause() {
        if !pendingCommit.isEmpty { setTentative("") }
        startFreshOnNextText = true
    }

    /// Utterance finished: keep it on screen briefly, then fade. The next words
    /// begin a new page rather than continuing this one.
    /// Utterance finished: the next words start a new page. Fading is handled by
    /// the text-idle poll, so there is nothing to arm here.
    func endUtterance() {
        // Fold in any commit that arrived without a following tentative — an
        // endpoint flush emits COMMITTED then ENDPOINT with nothing between.
        if !pendingCommit.isEmpty {
            setTentative("")
        }
        startFreshOnNextText = true
    }

    private func trimLeadingSpace(_ s: String) -> String {
        var out = s
        while out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    // MARK: layout / visibility

    private func layout() {
        let size = view.fittingSize(maxWidth: maxWidth)
        guard size.height > 0, let screen = NSScreen.main else { return }

        let anchor = self.anchor ?? NSPoint(x: screen.frame.midX,
                                            y: screen.frame.minY + screen.frame.height * 0.12)

        // Round the origin: a half-pixel x makes the text render soft as the box
        // resizes on every word.
        let origin = NSPoint(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded())
        // NSWindow resizes its content view itself, so assigning view.frame here
        // is redundant — and actively harmful: setFrame(display: true) paints
        // immediately, so a manual assignment afterwards means that paint happens
        // with the view still at its previous, smaller size and the text is drawn
        // clipped for a frame.
        isRepositioning = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        isRepositioning = false
    }

    private func saveAnchor() {
        guard let anchor else { return }
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Self.anchorKey)
    }

    private func fadeIfTextIdle() {
        guard !isDraggable, panel.alphaValue > 0 else { return }
        guard Date().timeIntervalSince(lastTextAt) >= textIdleTimeout else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // New text may have arrived during the fade and shown the panel again;
            // discarding the page then would throw away what is on screen.
            guard self.panel.alphaValue == 0 else { return }

            // Empty the box now that it is invisible, so the next words open a
            // clean one instead of resuming a paragraph nobody can still see.
            self.page = ""
            self.pendingCommit = ""
            self.tentative = ""
            self.view.committed = ""
            self.view.tentative = ""

            // `latestWordEnd` is deliberately *kept*: engines that never reset keep
            // growing one transcript, so "fresh" must mean "the words after this
            // moment in the audio", not "replay everything from the beginning".
            self.startFreshOnNextText = true
            self.onFaded?()
        })
    }

    private func show() {
        guard !isSuppressed else { return }
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func resetPosition() {
        anchor = nil
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        layout()
    }

    func setFontSize(_ size: CGFloat) {
        view.fontSize = size
        // Re-page at the new size: text that fit three lines at 22pt may need five
        // at 52pt, and without this the box would simply clip.
        if !page.isEmpty,
           view.lineCount(committed: page, tentative: "", width: maxWidth) > view.maxLines {
            page = ""
            view.committed = ""
            startFreshOnNextText = true
        }
        layout()
    }

    /// Pause and resume: drop what is on screen and stay dark until resumed.
    ///
    /// Distinct from `clearAndHide()`, which model and source switches use and
    /// which must *not* keep the overlay down — those are expected to start
    /// showing text again on their own.
    func setPaused(_ paused: Bool) {
        isSuppressed = paused
        if paused {
            clearAndHide()
            // Drop the drag state too, or a ⇧ held across the pause leaves the
            // panel catching clicks it will never show anything for.
            isDraggable = false
            panel.ignoresMouseEvents = true
        }
    }

    /// Wipe the box and fade it out, leaving it free to come back on the next
    /// word. Used when the engine underneath changes — model or source switch.
    func clearAndHide() {
        lastShownText = ""
        lastTextAt = .distantPast
        page = ""
        pendingCommit = ""
        tentative = ""
        pageStartTime = 0
        latestWordEnd = 0
        startFreshOnNextText = false
        view.committed = ""
        view.tentative = ""
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }
    }
}
