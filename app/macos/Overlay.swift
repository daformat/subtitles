// Phase 2 — the subtitle overlay.
//
// A borderless, click-through, never-focused panel that floats above everything
// including fullscreen apps. All the behaviour that made native the right call in
// PLAN.md §1 lives in this file: in Electron each of these is a flag that half
// works and regresses between versions.
//
// Interaction model: click-through by default, so the overlay never intercepts a
// click meant for the app underneath. Point at the box and it fades away under
// the cursor, so anything it is covering can be read without moving it. Hold ⇧
// to make it solid again and grabbable, and drag it somewhere else; the position
// is remembered. ⇧ rather than ⌥ because holding ⌥ while dragging a window puts
// macOS into its tiling preview, which fights the drag.
//
// Hold ⌥ and the last few closed pages stack up above the live box — see
// History.swift. The box pages like broadcast subtitles, so without it anything
// you glanced away from is gone for good.
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

    /// Draws the dashed ring that says the box can be picked up right now. Set
    /// while ⇧ is held, alongside the panel dropping its click-through.
    var showsDragOutline = false { didSet { needsDisplay = true } }

    /// Cursor position in view coordinates, or nil when the pointer is nowhere
    /// near (or ⇧ is held). Punches a soft hole through the box so whatever the
    /// overlay is covering can be read by pointing at it.
    var maskCenter: NSPoint? {
        didSet {
            switch (oldValue, maskCenter) {
            case (nil, nil): break
            case let (old?, new?) where old == new: break
            default: needsDisplay = true
            }
        }
    }

    /// Full extent of the reveal about the cursor. Wider than it is tall because
    /// the box is: a circle big enough to clear the pill's width overshoots its
    /// height several times over and takes far more of the screen with it than it
    /// needs to.
    /// Settable, because it is one of the numbers you can only judge by watching
    /// it move — see Settings.swift.
    var maskSize = SubtitleView.defaultMaskSize {
        didSet { if maskSize != oldValue, maskCenter != nil { needsDisplay = true } }
    }

    static let defaultMaskSize = NSSize(width: 800, height: 400)

    /// Fraction of the way out that stays fully clear before the falloff starts.
    /// Most of the radius, leaving the falloff the last third to spend.
    private static let maskPlateau: CGFloat = 0.7

    /// How much of the box the reveal takes at its strongest. 1 erases the pill
    /// outright under the cursor; lower leaves it showing through.
    var maskStrength: CGFloat = SubtitleView.defaultMaskStrength {
        didSet {
            guard maskStrength != oldValue else { return }
            // The falloff is baked into the gradient's stops, so a new strength
            // means a new gradient.
            builtGradient = nil
            if maskCenter != nil { needsDisplay = true }
        }
    }

    static let defaultMaskStrength: CGFloat = 0.95

    /// Weakest the reveal may be set to. Below about half, the hole stops
    /// reading as a hole — you get a slightly paler box and no sense that
    /// anything was revealed, which is a setting with nothing on the other end
    /// of it.
    static let minMaskStrength: CGFloat = 0.5

    /// Hard ceiling on displayed lines. The controller pages the text so this is
    /// never actually exceeded; the view clips as a last resort.
    var maxLines = SubtitleView.defaultMaxLines { didSet { needsDisplay = true } }

    static let defaultMaxLines = 2

    /// How solid the pill behind the text is. Zero is a legitimate setting —
    /// bare text over the picture, the way some players draw subtitles.
    var backgroundOpacity = SubtitleView.defaultBackgroundOpacity {
        didSet { if backgroundOpacity != oldValue { needsDisplay = true } }
    }

    static let defaultBackgroundOpacity: CGFloat = 0.72

    private let inset = Pill.inset
    private let corner = Pill.corner

    /// Transparent margin between the pill and the panel edge, where the ⇧ ring
    /// is drawn. Reserved on every layout rather than only while ⇧ is held: a
    /// window clips its own drawing, so the room for the ring has to exist
    /// before there is a ring, and growing the panel on keypress would mean
    /// re-laying it out mid-gesture.
    static let pad: CGFloat = 4

    /// The pill itself, inside that margin.
    private var boxRect: NSRect { bounds.insetBy(dx: Self.pad, dy: Self.pad) }

    /// Committed text at full strength, the in-flight tail dimmed.
    ///
    /// Spike 0A measured this engine as effectively non-revising (0 ms p50 commit
    /// lag, 4 of 66 words ever revised), so in practice the dimmed tail is usually
    /// empty. It stays because it costs nothing and is what makes a revising
    /// engine survivable if the model is ever swapped.
    func attributed(committed: String, tentative: String,
                    centered: Bool = true) -> NSAttributedString {
        Pill.attributed(committed: committed, tentative: tentative,
                        size: fontSize, centered: centered)
    }

    private func metrics(committed: String, tentative: String,
                         maxWidth: CGFloat) -> (used: NSSize, lines: Int) {
        Pill.metrics(attributed(committed: committed, tentative: tentative, centered: false),
                     textWidth: maxWidth - (inset.width + Self.pad) * 2)
    }

    func lineCount(committed: String, tentative: String, width: CGFloat) -> Int {
        metrics(committed: committed, tentative: tentative, maxWidth: width).lines
    }

    /// Size the box needs, hugging its content.
    ///
    /// `maxWidth` is a ceiling, not the width: a short line gets a short box.
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        Pill.fittingSize(attributed(committed: committed, tentative: tentative, centered: false),
                         size: fontSize, maxWidth: maxWidth,
                         maxLines: maxLines, pad: Self.pad)
    }

    /// A resize must repaint the whole box, not just the newly exposed strip.
    /// The reveal is punched through a transparency layer covering the entire
    /// pill, so a partial redraw would apply it to part of the box and leave the
    /// rest carrying the hole from the previous frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Falloff for the reveal, built once.
    ///
    /// Two parts. A flat core out to `maskPlateau`, held at full strength so the
    /// middle of the hole is properly gone rather than merely thinner — a falloff
    /// that starts at the very centre spends its whole span dimming and never
    /// reads as clear. Then a smoothstep tail, sampled rather than left as a pair
    /// of stops because CoreGraphics interpolates linearly between them and a
    /// straight ramp shows its edge.
    ///
    /// Smoothstep is flat at both ends, which is what makes the two parts join
    /// invisibly: the tail leaves the plateau at zero slope, so there is no crease
    /// where the core ends, and it lands on the untouched box the same way.
    private var builtGradient: CGGradient?

    /// Rebuilt only when the strength changes, so the 60 Hz cursor poll still
    /// draws against a gradient it did not have to sample.
    private var maskGradient: CGGradient? {
        if let builtGradient { return builtGradient }
        builtGradient = Self.buildMaskGradient(strength: maskStrength)
        return builtGradient
    }

    private static func buildMaskGradient(strength: CGFloat) -> CGGradient? {
        let space = CGColorSpaceCreateDeviceRGB()
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        func stop(_ location: CGFloat, alpha: CGFloat) {
            guard let c = CGColor(colorSpace: space, components: [0, 0, 0, alpha]) else { return }
            colors.append(c)
            locations.append(location)
        }

        stop(0, alpha: strength)
        stop(maskPlateau, alpha: strength)

        let steps = 32
        for i in 1...steps {
            let u = CGFloat(i) / CGFloat(steps)          // 0…1 across the tail
            // Scaled by `strength` too, or the tail would start above the plateau
            // it is meant to leave and draw a bright ring around the hole.
            stop(maskPlateau + u * (1 - maskPlateau),
                 alpha: strength * (1 - u * u * (3 - 2 * u)))
        }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }

    /// Cuts the reveal out of everything drawn so far.
    private func punchMask(_ ctx: CGContext, at center: NSPoint) {
        guard let gradient = maskGradient else { return }
        ctx.saveGState()
        // The gradient's alpha is subtracted from what is already on the layer,
        // so opaque centre = fully transparent box.
        ctx.setBlendMode(.destinationOut)
        // CoreGraphics radial gradients are circular, so the ellipse comes from
        // squashing the space it is drawn in: move the origin to the cursor,
        // scale y, then draw a circle of the half-width there.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: maskSize.height / maskSize.width)
        ctx.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: maskSize.width / 2,
            options: [])
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributed(committed: committed, tentative: tentative)
        guard text.length > 0 else { return }

        // Pill, ring and text have to be composited into one image before the
        // hole is cut: `.destinationOut` only erases what is already in the
        // destination, so without a transparency layer it would eat the pill and
        // leave the text — and the text is the opaque part.
        let ctx = NSGraphicsContext.current?.cgContext
        if maskCenter != nil { ctx?.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer {
            if let ctx, let center = maskCenter {
                punchMask(ctx, at: center)
                ctx.endTransparencyLayer()
            }
        }

        let box = boxRect
        NSColor.black.withAlphaComponent(backgroundOpacity).setFill()
        NSBezierPath(roundedRect: box, xRadius: corner, yRadius: corner).fill()

        if showsDragOutline {
            // Just enough to say it can be picked up now: a hairline dashed ring
            // sitting off the pill, the same hint the web demo gives. Half a
            // point in from the panel edge so the stroke lands on the pixel
            // instead of straddling it.
            //
            // Two-tone, because the ring is drawn over whatever is on the desktop
            // and a single colour loses to half of it — white vanished against a
            // white window. `.difference` is the obvious answer and is not
            // available: a blend mode composites against what is already in *this
            // window*, and the ring hangs in the transparent margin outside the
            // pill, where there is nothing to blend with. The desktop behind is
            // composited by the window server long after this draw call. So the
            // contrast has to be carried in the ink itself: white dashes, black
            // dashes phase-shifted into the gaps between them, and whichever tone
            // the background happens to be, the other one shows against it.
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: corner + Self.pad, yRadius: corner + Self.pad)
            ring.lineWidth = 1

            let dash: [CGFloat] = [3, 3]
            ring.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.white.withAlphaComponent(0.75).setStroke()
            ring.stroke()

            // Offset by exactly one dash, so the black lands in the gaps the
            // white left rather than on top of it.
            ring.setLineDash(dash, count: dash.count, phase: dash[0])
            NSColor.black.withAlphaComponent(0.75).setStroke()
            ring.stroke()
        }

        text.draw(with: box.insetBy(dx: inset.width, dy: inset.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - Controller

final class OverlayController {
    private let panel: SubtitlePanel
    private let view: SubtitleView
    private var idleTimer: Timer?
    private var modifierTimer: Timer?
    private var cursorTimer: Timer?
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
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

    /// When the page currently on screen was opened.
    ///
    /// Gates the clause carried across a page break. Carrying exists for a box
    /// that turns over before it can be read; a box that has been up as long as
    /// the idle fade would have allowed has already given the reader that time,
    /// and repeating its last clause then only spends room in the new box on text
    /// they are done with.
    private var pageShownAt = Date.distantPast

    /// Whether the page about to close turned over quickly enough to be worth
    /// carrying a clause from.
    private var allowsCarry: Bool {
        Date().timeIntervalSince(pageShownAt) < textIdleTimeout
    }
    private var isDraggable = false

    /// How solid the box behind the text is, 0…1. The ⌥ stack follows it, a step
    /// behind — see `HistoryPillView.recession`.
    var boxOpacity: CGFloat {
        get { view.backgroundOpacity }
        set { view.backgroundOpacity = newValue }
    }

    /// How much of the box the pointer reveal takes, 0…1.
    var revealOpacity: CGFloat {
        get { view.maskStrength }
        set { view.maskStrength = newValue }
    }

    /// Full extent of that reveal.
    var revealSize: NSSize {
        get { view.maskSize }
        set { view.maskSize = newValue }
    }

    /// The untranslated transcript, kept even while the translated one is on
    /// screen, so ⌃ can show the original without waiting for new speech.
    private var sourceWords: [TimedWord] = []
    /// The translated rendering, when there is one: words, the dimmed tail, and
    /// the chunk boundaries paging carries across a break.
    private var translatedWords: ([TimedWord], String, [TimeInterval])?
    /// Set while a translation target is chosen. Without it a stale translation
    /// would keep being drawn after translation was switched off.
    var prefersTranslation = false {
        didSet {
            guard prefersTranslation != oldValue else { return }
            if !prefersTranslation { translatedWords = nil }
            redraw()
        }
    }
    /// ⌃ held: show the original language for as long as it is down.
    ///
    /// Polled with ⇧ rather than watched with an event monitor, for the reason in
    /// the file header: a keyboard monitor would demand Accessibility permission,
    /// and a second scary prompt to peek at a caption is a bad trade.
    private var showsSource = false

    /// Whether the overlay is captured by screen recording and sharing.
    ///
    /// `sharingType = .none` asks the window server to leave the window out of
    /// what any other process can read, which is how password managers keep
    /// themselves out of screenshots. It applies to the capture itself rather than
    /// to any one app, so it covers Zoom, QuickTime and Screenshot alike without
    /// naming any of them — and it is not a promise about a camera pointed at the
    /// screen.
    ///
    /// On by default. Subtitles you cannot share are the surprising choice, and a
    /// setting that hides things should be one the user reached for.
    var isVisibleInScreenShare = true {
        didSet {
            panel.sharingType = isVisibleInScreenShare ? .readOnly : .none
            history.isVisibleInScreenShare = isVisibleInScreenShare
        }
    }

    /// Whether pointing at the box fades it away. On by default; the menu turns it
    /// off for anyone who would rather the subtitles simply stayed put.
    var isRevealEnabled = true {
        didSet {
            // Close any hole that is open right now — the next poll would leave it
            // there, since a disabled reveal stops updating the centre at all.
            if !isRevealEnabled { view.maskCenter = nil }
        }
    }

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

    // ── history ──
    // Pages that have scrolled off, oldest first, brought back by holding ⌥.
    // Recorded at every point a page closes rather than sampled, because by the
    // time a page is gone from `page` there is nothing left to read it from.
    private let history = HistoryController()
    /// Pages a stream exactly as the live box does, without drawing it.
    ///
    /// Both languages need real page memory, not one reconstructed from the other:
    /// deriving the original from the span a translated page covered is right only
    /// where the break happened to fall on a chunk boundary, and wrong by a word
    /// or two everywhere else. Worse, a span with nothing in it has to fall back
    /// to the text it was derived from, which puts a translated box in the middle
    /// of a stack that is meant to be the original.
    ///
    /// So each stream keeps its own. The hidden one is paged too, using the same
    /// fitting rule, so ⌃ finds a stack that was built rather than inferred.
    private struct StreamPager {
        private(set) var closed: [String] = []
        private var anchor: TimeInterval = 0
        private var latest: TimeInterval = 0
        private var currentWords: [TimedWord] = []
        private var freshNext = false
        /// Where the last closed page actually ended.
        ///
        /// Pages overlap on purpose when translating: a page restarts at the last
        /// clause it showed, so that clause opens the next box and stays readable
        /// across the break. In the stack that repetition is only noise, since the
        /// box above still ends with it, so history keeps just what each page
        /// added past this point.
        private var previousEnd: TimeInterval = -.greatestFiniteMagnitude

        /// The next words start a page of their own: a pause, or an endpoint.
        mutating func markFresh() { freshNext = true }

        mutating func clear() {
            closed.removeAll()
            anchor = 0
            latest = 0
            currentWords = []
            freshNext = false
            previousEnd = -.greatestFiniteMagnitude
        }

        mutating func trim(to depth: Int) {
            guard closed.count > depth else { return }
            closed.removeFirst(closed.count - depth)
        }

        /// `fits` is the caller's measurement: how many of these words fit a box.
        mutating func ingest(_ words: [TimedWord], chunkStarts: [TimeInterval],
                             depth: Int, allowCarry: Bool, fits: ([String]) -> Int) {
            guard let newest = words.last else { return }
            // A transcript that has gone backwards is a restarted one.
            if newest.end < latest {
                anchor = 0
                latest = 0
            }
            if freshNext {
                freshNext = false
                append(currentWords, depth: depth)
                anchor = latest
                previousEnd = latest
            }
            latest = max(latest, newest.end)

            var visible = words.filter { $0.start >= anchor }
            guard !visible.isEmpty else { return }
            while true {
                let fitted = fits(visible.map(\.text))
                if fitted >= visible.count { break }
                if fitted <= 0 { break }
                let spilled = visible[fitted].start
                let leading = visible[0].start
                let carried = allowCarry ? chunkStarts.last { $0 > leading && $0 < spilled } : nil
                // Where the next box starts. History keeps only what will not
                // reappear there, so the stack runs continuously into the live box
                // instead of repeating the clause it carried over.
                let nextAnchor = carried ?? spilled
                append(visible.filter { $0.start < nextAnchor }, depth: depth)
                previousEnd = nextAnchor
                anchor = nextAnchor
                visible = visible.filter { $0.start >= anchor }
            }
            currentWords = visible
        }

        /// Store only what this page added, so a carried clause is not repeated in
        /// the box below the one that already ends with it.
        private mutating func append(_ words: [TimedWord], depth: Int) {
            guard depth > 0 else { return }
            let fresh = words.filter { $0.start >= previousEnd }
            let text = fresh.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != closed.last else { return }
            closed.append(text)
            trim(to: depth)
        }
    }

    private var sourcePager = StreamPager()
    private var translatedPager = StreamPager()

    /// The stack for whichever language is on screen.
    private var pastPages: [String] {
        showsSource || !prefersTranslation ? sourcePager.closed : translatedPager.closed
    }

    /// How many closed pages ⌥ can reach back through. Adjustable in Settings;
    /// lowering it drops the oldest immediately rather than waiting for the
    /// buffer to be pushed down to the new size. Zero keeps none at all, which
    /// is how someone turns the whole thing off without losing the ⌥ gesture
    /// having ever meant anything.
    var historyDepth = OverlayController.defaultHistoryDepth {
        didSet {
            guard historyDepth != oldValue else { return }
            sourcePager.trim(to: historyDepth)
            translatedPager.trim(to: historyDepth)
        }
    }

    static let defaultHistoryDepth = 15

    /// How bright the ⌥ stack's text is against the live box's white.
    var historyTextOpacity = HistoryPillView.defaultTextOpacity

    /// Forget the stack after this long with no new text, so ⌥ pressed an hour
    /// later does not answer with whatever was on screen before lunch. Off keeps
    /// it until a pause or a model switch.
    var historyExpiry: TimeInterval = OverlayController.defaultHistoryExpiry
    var isHistoryExpiryEnabled = true

    /// Half a minute. Long enough to cover a pause in the conversation, short
    /// enough that the stack is about what was *just* said.
    static let defaultHistoryExpiry: TimeInterval = 30

    /// Whether ⌥ brings the last few boxes back. Menu-controlled, like the
    /// pointer reveal.
    var isHistoryEnabled = true {
        didSet { if !isHistoryEnabled { history.dismiss() } }
    }
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
            // The anchor is the pill's bottom edge, not the panel's: the panel
            // carries a transparent margin for the ⇧ ring, and folding that into
            // the anchor would walk the box a few points down on every drag.
            self.anchor = NSPoint(x: self.panel.frame.midX,
                                  y: self.panel.frame.minY + SubtitleView.pad)
        }

        // Resolution changed, a display arrived or left, or the arrangement
        // moved. The remembered position is in the coordinates of a screen that
        // no longer exists at that size, so the box can be sitting off the edge
        // of the new one — and `maxWidth`, which decides where the text pages,
        // has changed with it.
        //
        // An untouched overlay derives its position from the screen on every
        // layout and so fixes itself, but only on the next word: a machine that
        // is quiet across the change stays wrong until somebody speaks.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenChanged()
        }

        // Polled rather than armed per update: a one-shot timer must be cancelled
        // and re-armed on every text change, and anything that forgets to re-arm
        // strands the overlay on screen — which is exactly the bug this replaces.
        // A poll cannot be forgotten.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.fadeIfTextIdle()
            self?.expireHistoryIfIdle()
        }

        // ⇧ toggles grabbable. Polled, not monitored — see the file header.
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Not while paused: the panel is invisible then, and making an
            // invisible panel grabbable just means it swallows clicks meant for
            // whatever is underneath.
            // ⌃ peeks at the original language. Checked before the drag branch
            // because it changes what is drawn, not how the panel behaves, and the
            // two are independent: peeking while dragging is fine.
            let wantsSource = NSEvent.modifierFlags.contains(.control)
            if wantsSource != self.showsSource {
                self.showsSource = wantsSource
                self.redraw()
            }

            let wantsDrag = NSEvent.modifierFlags.contains(.shift) && !self.isSuppressed
            if wantsDrag != self.isDraggable {
                self.isDraggable = wantsDrag
                self.panel.ignoresMouseEvents = !wantsDrag
                self.view.showsDragOutline = wantsDrag
                // Nudge visible while it can be grabbed, so it is obvious the
                // overlay is now catching clicks instead of passing them through.
                if wantsDrag { self.panel.alphaValue = 1.0 }
                if !wantsDrag { self.saveAnchor() }
            }
        }

        // Cursor tracking for the reveal. Polled for the same reason ⇧ is (see
        // the file header) and because the panel is click-through: it receives no
        // mouse events of its own, so there is nothing to track from.
        //
        // Its own timer at frame rate rather than a job on the 0.15s modifier
        // poll: the hole is attached to the pointer, and at 0.15s it visibly lags
        // behind it. Added to `.common` so the reveal keeps following while a menu
        // or a resize has the run loop in a tracking mode.
        let cursor = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateHistory()
            self?.updateMask()
        }
        RunLoop.main.add(cursor, forMode: .common)
        cursorTimer = cursor
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        idleTimer?.invalidate()
        modifierTimer?.invalidate()
        cursorTimer?.invalidate()
    }

    /// Raise or drop the ⌥ stack.
    ///
    /// Rebuilt whenever the entries differ from what is on screen, so a page
    /// closing while ⌥ is still held joins the stack immediately — `present`
    /// leaves boxes that were already up alone and animates only the new one.
    private func updateHistory() {
        let flags = NSEvent.modifierFlags
        // Never alongside ⇧: that is the drag gesture, and a second panel over
        // the box while it is being picked up just gets in the way.
        let wants = isHistoryEnabled && !isSuppressed && !pastPages.isEmpty
            && flags.contains(.option) && !flags.contains(.shift)
        guard wants else {
            history.dismiss()
            return
        }

        // The stack follows the live box: peeking at the original with ⌃ and
        // leaving the boxes above it translated would be the worst of both.
        let entries = pastPages
        if history.shown != entries {
            let style = HistoryStyle(
                fontSize: view.fontSize,
                maxLines: view.maxLines,
                fill: view.backgroundOpacity * HistoryPillView.recession,
                textOpacity: historyTextOpacity)
            history.present(entries: entries, style: style,
                            anchor: panel.frame, maxWidth: maxWidth)
        } else {
            // The live box resizes on every word; the stack rides along with it.
            history.reposition(anchor: panel.frame)
        }
    }

    /// Point the reveal at the cursor, or turn it off.
    ///
    /// ⇧ is read here rather than reusing `isDraggable` so the box goes solid the
    /// moment the key is down: `isDraggable` only catches up on the next 0.15s
    /// modifier poll, which is long enough to start a drag through a hole.
    ///
    /// ⌥ suppresses it for a different reason: the pointer has to be over the
    /// stack to scroll it, and a hole punched through the live box under the
    /// cursor while the user is reading the history above it is pure noise.
    /// `frame` is the panel frame to measure against, for the case where the
    /// panel is about to be given one and has not got it yet.
    private func updateMask(for frame: NSRect? = nil) {
        let panelFrame = frame ?? panel.frame
        let flags = NSEvent.modifierFlags
        guard isRevealEnabled,
              panel.alphaValue > 0,
              !flags.contains(.shift),
              !flags.contains(.option) else {
            view.maskCenter = nil
            return
        }

        // Cheap reject before converting: only a cursor within the reveal's reach
        // of the panel can affect a pixel of it. The reach is wide enough that the
        // box starts opening before the pointer is over it.
        let reach = view.maskSize
        let point = NSEvent.mouseLocation
        guard panelFrame.insetBy(dx: -reach.width / 2, dy: -reach.height / 2).contains(point) else {
            view.maskCenter = nil
            return
        }
        // Subtraction rather than the panel's own coordinate conversion: this is
        // called before the panel has been given `frame`, so asking the panel
        // where a screen point lands would answer for the frame it is leaving. A
        // borderless panel's content view fills its frame exactly, so the two
        // agree in every other respect.
        view.maskCenter = NSPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
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
    /// `speculative` is an unfinished tail rendered in the dimmed style — text the
    /// app expects to replace. Live translation is the first thing to use it: the
    /// sentence being spoken is translated before it is finished, so it is shown
    /// as provisional until the settled version arrives. Empty for transcription,
    /// where the recogniser barely revises at all.
    /// The transcript as spoken. Always stored, drawn when there is no translation
    /// to show or while ⌃ is held.
    func setSourceWords(_ words: [TimedWord]) {
        sourceWords = words
        page(&sourcePager, words, chunkStarts: [])
        guard !prefersTranslation || showsSource || translatedWords == nil else { return }
        showWords(words)
    }

    /// The transcript translated. Stored and drawn unless ⌃ is asking for the
    /// original.
    func setTranslatedWords(_ words: [TimedWord], speculative: String,
                            chunkStarts: [TimeInterval]) {
        translatedWords = (words, speculative, chunkStarts)
        page(&translatedPager, words, chunkStarts: chunkStarts)
        guard !showsSource else { return }
        showWords(words, speculative: speculative, chunkStarts: chunkStarts)
    }

    /// Run a stream through its own pager, measuring with the live box's geometry
    /// so the hidden stack breaks where it would have if it were on screen.
    private func page(_ pager: inout StreamPager, _ words: [TimedWord],
                      chunkStarts: [TimeInterval]) {
        pager.ingest(words, chunkStarts: chunkStarts, depth: historyDepth,
                     allowCarry: allowsCarry) { texts in
            longestFittingPrefix(texts, from: 0)
        }
    }

    /// Draw whichever rendering is currently wanted, from what is already held.
    ///
    /// Paging is anchored on audio time and the two renderings do not share one,
    /// so the anchor is dropped and the page refilled from the start of what is
    /// available. The overflow loop then lands on the tail, which is what was on
    /// screen a moment ago.
    private func redraw() {
        pageStartTime = 0
        latestWordEnd = 0
        lastShownText = ""
        // Only the live box is redrawn. The stacks are built by the pagers as
        // words arrive, so a ⌃ toggle picks a different one rather than rebuilding
        // it, and repainting cannot duplicate anything.
        defer { updateHistory() }
        if showsSource || !prefersTranslation || translatedWords == nil {
            guard !sourceWords.isEmpty else { return }
            showWords(sourceWords)
        } else if let (words, speculative, chunks) = translatedWords {
            showWords(words, speculative: speculative, chunkStarts: chunks)
        }
    }

    /// `chunkStarts` are the audio times settled units begin at, when the caller
    /// has such units. Live translation does: it settles a clause at a time. Given
    /// them, a page that overflows restarts at the last chunk boundary it showed
    /// rather than at the word that spilled, so the final clause of the old box
    /// opens the new one and stays readable across the break. Empty for
    /// transcription, which pages as it always has.
    func showWords(_ words: [TimedWord], speculative: String = "",
                   chunkStarts: [TimeInterval] = []) {
        guard !isSuppressed else { return }
        guard let newest = words.last else {
            // A speculative tail can exist before anything has settled — the first
            // seconds of live translation are nothing but tail.
            //
            // This does the same bookkeeping as the settled path below rather than
            // handing off to `setTentative`, because `lastTextAt` is what holds the
            // idle poll off. Routing through `setTentative`, which never sets it,
            // meant the box faded every 0.5 s while updates kept calling `show()`
            // to bring it back: one blink per word.
            guard !speculative.isEmpty else { return }
            lastTextAt = Date()
            guard speculative != tentative || !page.isEmpty else { return }
            page = ""
            pendingCommit = ""
            tentative = speculative
            lastShownText = ""
            view.committed = ""
            view.tentative = speculative
            layout()
            show()
            return
        }

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
            pageShownAt = Date()
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

        // Advance the page while the visible text overflows. The speculative tail
        // takes part in the measurement — it is on screen, so a page sized without
        // it overflows the moment the tail is drawn.
        while true {
            let fitted = longestFittingPrefix(visible.map(\.text), from: 0,
                                              tentative: speculative)
            if fitted >= visible.count { break }   // it all fits
            if fitted <= 0 { break }               // one word wider than the box

            let spilled = visible[fitted].start
            // Back up to the last chunk boundary on the closing page, so that
            // clause reappears at the top of the new one and stays readable across
            // the break.
            //
            // Bounded strictly by the *first visible word*, not by `pageStartTime`:
            // a boundary at or before the leading word filters nothing out, so the
            // next pass would compute the same spill and the same carry and never
            // terminate. Anchoring past it guarantees at least one word leaves, and
            // with a single chunk filling the box there is nothing to carry and the
            // spill is used unchanged.
            let leading = visible[0].start
            let carried = allowsCarry ? chunkStarts.last { $0 > leading && $0 < spilled } : nil
            pageStartTime = carried ?? spilled
            pageShownAt = Date()
            visible = visible.filter { $0.start >= pageStartTime }
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
        // The tail is part of what is on screen, so an unchanged transcript with a
        // changed tail is still new information. Comparing only `text` here left
        // the live translation frozen on its first guess.
        guard text != lastShownText || speculative != tentative else { return }
        lastShownText = text
        lastTextAt = Date()

        page = text
        pendingCommit = ""
        tentative = speculative
        view.committed = page
        view.tentative = speculative
        layout()
        show()
    }

    /// Index one past the last word that still fits within `maxLines`.
    private func longestFittingPrefix(_ words: [String], from start: Int,
                                      tentative: String = "") -> Int {
        var end = start
        while end < words.count {
            let candidate = words[start...end].joined(separator: " ")
            if view.lineCount(committed: candidate, tentative: tentative,
                              width: maxWidth) > view.maxLines {
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
        markPagersFresh()
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
        markPagersFresh()
    }

    /// A page just left the screen. Keep it for ⌥.
    ///
    /// Deduplicated against the last entry: a page can close by more than one
    /// route in the same beat — an overflow immediately after a pause, say — and
    /// two identical boxes in the stack read as a stutter, not as history.
    /// The next words begin a page of their own, in both languages.
    private func markPagersFresh() {
        sourcePager.markFresh()
        translatedPager.markFresh()
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
        // resizes on every word. The y drops by the ring margin so the *pill*
        // still sits on the anchor — the margin is invisible, and the box would
        // otherwise appear to float a few points above where it was left.
        let origin = NSPoint(x: (anchor.x - size.width / 2).rounded(),
                             y: (anchor.y - SubtitleView.pad).rounded())
        // NSWindow resizes its content view itself, so assigning view.frame here
        // is redundant — and actively harmful: setFrame(display: true) paints
        // immediately, so a manual assignment afterwards means that paint happens
        // with the view still at its previous, smaller size and the text is drawn
        // clipped for a frame.
        // The reveal's centre is in view coordinates, so a layout that moves the
        // panel's origin invalidates it — and `setFrame(display:)` paints
        // immediately, so the stale centre is what gets painted. A box can go
        // from 140 to 900 points wide on one word, which moves the origin by most
        // of the box: the hole lands off the pointer for a frame or two, and
        // reads as the reveal blinking out. Recomputed here against the frame
        // about to be set, so the first paint is already right.
        let frame = NSRect(origin: origin, size: size)
        updateMask(for: frame)
        isRepositioning = true
        panel.setFrame(frame, display: true)
        isRepositioning = false
    }

    /// Bring the box back onto the screen it is now on, and lay it out there.
    ///
    /// The anchor is written back rather than only applied: it is what gets
    /// saved, and a position that is off the current display is not one to keep
    /// remembering.
    private func screenChanged() {
        guard let screen = NSScreen.main else { return }
        if let current = anchor {
            let clamped = clamp(current, to: screen)
            if clamped != current {
                anchor = clamped
                saveAnchor()
            }
        }
        // Empty box: `layout()` returns early and there is nothing to move, but
        // the anchor above is now right for the next word.
        layout()
    }

    /// Hold the pill inside the screen's visible frame.
    ///
    /// The anchor is the pill's bottom centre, so the clamp is against half a
    /// width either side and the box's own height above. A box wider or taller
    /// than the screen has no valid position, and centring it is the least
    /// surprising answer.
    private func clamp(_ point: NSPoint, to screen: NSScreen) -> NSPoint {
        let area = screen.visibleFrame
        let size = panel.frame.size
        let half = size.width / 2

        let x = area.width >= size.width
            ? min(max(point.x, area.minX + half), area.maxX - half)
            : area.midX
        let lowest = area.minY + SubtitleView.pad
        let highest = area.maxY - size.height + SubtitleView.pad
        let y = highest >= lowest ? min(max(point.y, lowest), highest) : lowest
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func saveAnchor() {
        guard let anchor else { return }
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Self.anchorKey)
    }

    /// Drop the ⌥ stack once the transcript has been quiet long enough.
    ///
    /// Measured from the last *text*, not the last audio, for the same reason
    /// the fade is: a backing track keeps the voice gate open indefinitely, and
    /// what matters is whether new words are arriving.
    private func expireHistoryIfIdle() {
        guard isHistoryExpiryEnabled, !pastPages.isEmpty else { return }
        // Not while it is on screen. Someone holding ⌥ is reading it, and a
        // stack that empties under their eyes because nobody spoke for a minute
        // is the one moment this must not fire.
        guard history.shown.isEmpty else { return }
        guard Date().timeIntervalSince(lastTextAt) >= historyExpiry else { return }
        sourcePager.clear()
        translatedPager.clear()
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
            // clean one instead of resuming a paragraph nobody can still see —
            // but keep it for ⌥ first. Fading is precisely when someone looks
            // away and wants it back.
            self.markPagersFresh()
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

    /// How many lines a box may fill before it is closed and a new one begun.
    var maxLines: Int {
        get { view.maxLines }
        set {
            guard newValue != view.maxLines else { return }
            view.maxLines = newValue
            // Re-page at the new ceiling, for the same reason a font size change
            // does: what fitted five lines does not fit two, and without this the
            // box already on screen would simply be clipped.
            if !page.isEmpty,
               view.lineCount(committed: page, tentative: "", width: maxWidth) > view.maxLines {
                markPagersFresh()
                page = ""
                view.committed = ""
                startFreshOnNextText = true
            }
            layout()
        }
    }

    func setFontSize(_ size: CGFloat) {
        view.fontSize = size
        // Re-page at the new size: text that fit three lines at 22pt may need five
        // at 52pt, and without this the box would simply clip.
        if !page.isEmpty,
           view.lineCount(committed: page, tentative: "", width: maxWidth) > view.maxLines {
            markPagersFresh()
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
            view.showsDragOutline = false
        }
    }

    /// Wipe the box and fade it out, leaving it free to come back on the next
    /// word. Used when the engine underneath changes — model or source switch.
    func clearAndHide() {
        // The history goes with it. It survives the idle fade on purpose, but a
        // pause or a model switch is the user saying this transcript is over, and
        // ⌥ offering the last thing a since-replaced model heard is a puzzle.
        sourcePager.clear()
        translatedPager.clear()
        history.dismiss()
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
