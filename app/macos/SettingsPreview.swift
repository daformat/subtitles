// The live preview in the Settings window.
//
// Every dial in the UI pane governs something that can only be judged by
// watching it, and the overlay itself is meant to be that preview. It is —
// while there is something on it. Half of these settings say what happens to
// boxes that have already finished (the ⌥ stack), one describes a hole that
// follows a pointer currently busy holding a slider, and none of them show
// anything at all on a quiet machine. Opening Settings in the middle of a film
// is the rare case; opening it to find out what these do is the common one.
//
// So the pane carries a small screen of its own. It is not a drawing of the
// overlay: it instantiates `SubtitleView` and `HistoryPillView` and scales them
// down, so what is on it is the overlay's own paging, pill geometry, reveal
// gradient and text — and cannot drift from them, because there is no second
// copy to drift.
//
// The text is always scripted, never the live transcript. Mirroring the real
// thing was tried first and is worse: it is empty on a quiet machine, which is
// most of the time this window is open, and when it is not empty it is someone
// else's sentence arriving mid-drag and re-paging the box under the hand that
// is holding the slider. A loop that types itself out, fills to the line limit,
// clears and drops what it closed into the stack demonstrates all of that on
// demand — and can say what each control does as it is touched, in a sentence
// carrying that control's current value.
//
// The ⌥ stack is raised the way ⌥ raises it, staggered boxes rising out of the
// live one, whenever a control that governs it is touched — and by holding ⌥
// itself, which works here as well as over the overlay.

import AppKit

/// Everything the preview needs to draw a frame, gathered from the same getters
/// the rows read. Passed whole on every edit rather than set piecemeal: the
/// preview rebuilds from it, so a missed field would be a stale pill rather
/// than a compile error.
struct PreviewStyle: Equatable {
    var fontSize: CGFloat = 30
    var maxLines = SubtitleView.defaultMaxLines
    var boxOpacity = SubtitleView.defaultBackgroundOpacity
    var revealOpacity = SubtitleView.defaultMaskStrength
    var revealSize = SubtitleView.defaultMaskSize
    var revealEnabled = true
    var historyEnabled = true
    var historyDepth = OverlayController.defaultHistoryDepth
    var historyTextOpacity = HistoryPillView.defaultTextOpacity
    var historyExpiry = OverlayController.defaultHistoryExpiry
    var historyExpires = true
}

/// Which control was last touched, so the box can explain that one.
enum PreviewTopic {
    case lines, background, reveal, keep, dimness, expiry
}

// MARK: - Palette

/// The site demo's two palettes, as it states them.
///
/// The demo swaps a whole screen between light and dark rather than tinting one:
/// a different wallpaper, a different window, a different weight of shadow under
/// it. Both are ported here so the preview follows the appearance the way the
/// demo in the Welcome window does — the two sit a menu apart, and one of them
/// staying dark in a light window looks like a bug in the other.
///
/// What does *not* change is the caption box. The overlay is black with white
/// text over whatever is playing, in either appearance, and the demo draws it
/// that way too.
private struct DesktopPalette {
    /// Things drawn *on* a surface, at whatever alpha each one wants — the
    /// stylesheet's `--ink`, and the reason its alphas hold across the swap.
    let ink: NSColor
    /// Three stops, top to bottom.
    let wallpaper: [NSColor]
    let glowA: NSColor
    let glowB: NSColor
    let window: NSColor
    /// Ink alphas: the title bar's gradient, and the hairline it ends on.
    let barTop: CGFloat
    let barBottom: CGFloat
    let line: CGFloat
    /// Ink alpha for the page of text inside the window.
    let content: CGFloat
    /// `--border-strong`, around the screen and the window.
    let edge: NSColor
    /// Shadows are the one thing that does not survive a palette swap: the dark
    /// one is deep because it falls on a near-black desktop, where nothing less
    /// reads at all, and the same shadow on a light one is a smear.
    let shadow: CGFloat

    static let light = DesktopPalette(
        ink: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.110, alpha: 1),   // 22 23 28
        wallpaper: [
            NSColor(srgbRed: 0.804, green: 0.839, blue: 0.949, alpha: 1),    // #cdd6f2
            NSColor(srgbRed: 0.902, green: 0.902, blue: 0.957, alpha: 1),    // #e6e6f4
            NSColor(srgbRed: 0.949, green: 0.933, blue: 0.941, alpha: 1),    // #f2eef0
        ],
        glowA: NSColor(srgbRed: 0.588, green: 0.612, blue: 1, alpha: 0.50),
        glowB: NSColor(srgbRed: 1, green: 0.690, blue: 0.588, alpha: 0.45),
        window: NSColor(srgbRed: 0.992, green: 0.992, blue: 1, alpha: 1),    // #fdfdff
        barTop: 0.06, barBottom: 0.13, line: 0.13,
        content: 0.13,
        edge: NSColor(srgbRed: 0.071, green: 0.071, blue: 0.094, alpha: 0.16),
        shadow: 0.20)

    static let dark = DesktopPalette(
        ink: .white,
        wallpaper: [
            NSColor(srgbRed: 0.165, green: 0.169, blue: 0.271, alpha: 1),    // #2a2b45
            NSColor(srgbRed: 0.098, green: 0.102, blue: 0.165, alpha: 1),    // #191a2a
            NSColor(srgbRed: 0.063, green: 0.063, blue: 0.098, alpha: 1),    // #101019
        ],
        glowA: NSColor(srgbRed: 0.471, green: 0.455, blue: 1, alpha: 0.34),
        glowB: NSColor(srgbRed: 0.306, green: 0.290, blue: 0.745, alpha: 0.30),
        window: NSColor(srgbRed: 0.063, green: 0.067, blue: 0.086, alpha: 1), // #101116
        barTop: 0.09, barBottom: 0.045, line: 0.045,
        content: 0.13,
        edge: NSColor(white: 1, alpha: 0.18),
        shadow: 0.55)

    /// The palette a view should be drawing in right now.
    static func matching(_ appearance: NSAppearance) -> DesktopPalette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

// MARK: - Stage

/// A view whose contents are laid out in overlay points and drawn at whatever
/// fraction of that fits the window.
///
/// The scale lives in the bounds rather than in the numbers handed to the
/// subviews. Shrinking a font to 11pt and leaving `Pill.inset` at its 22 points
/// would draw a small caption in a large pill — every proportion in the box is
/// tuned against the others, and scaling one of them is how a preview starts
/// lying. A bounds transform scales all of them at once, including the ones this
/// file never mentions.
private final class PreviewStage: NSView {
    /// On-screen points per overlay point.
    var contentScale: CGFloat = 1 { didSet { applyScale() } }
    var onResize: (() -> Void)?

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    private func applyScale() {
        guard contentScale > 0 else { return }
        let scaled = NSSize(width: (frame.width / contentScale).rounded(),
                            height: (frame.height / contentScale).rounded())
        guard scaled != bounds.size, scaled.width > 0, scaled.height > 0 else { return }
        setBoundsSize(scaled)
        onResize?()
    }

    /// A desktop for the subtitles to sit on, and a window for the pointer
    /// reveal to reveal. A hole punched onto the settings window's own
    /// background would show nothing being uncovered, which is the one thing
    /// that control is about.
    ///
    /// The wallpaper is the site demo's: the same two glows over the same
    /// three-stop ground, in whichever of its two palettes matches the
    /// appearance this window is being drawn in.
    ///
    /// Everything here is in overlay points, which are the simulated screen's
    /// own points — so the title bar is 28 of them and the traffic lights 12
    /// across, exactly as they are on the Mac this is pretending to be, and the
    /// stage's scale takes them down with everything else.
    override func draw(_ dirtyRect: NSRect) {
        let palette = DesktopPalette.matching(effectiveAppearance)
        drawDesktop(palette)
        drawWindow(palette)
    }

    /// Repaint on a change of appearance. The colours are picked in `draw`, so
    /// there is nothing to update — only a reason to draw again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawDesktop(_ palette: DesktopPalette) {
        NSGradient(colors: palette.wallpaper, atLocations: [0, 0.46, 1], colorSpace: .sRGB)?
            // CSS measures its 158° clockwise from up; NSGradient measures
            // counter-clockwise from the x axis, which is 90 less than it.
            .draw(in: bounds, angle: -68)

        glow(at: NSPoint(x: 0.22, y: 0.92), radii: NSSize(width: 0.60, height: 0.70),
             color: palette.glowA)
        glow(at: NSPoint(x: 0.88, y: 0.04), radii: NSSize(width: 0.52, height: 0.60),
             color: palette.glowB)
    }

    /// One of the wallpaper's soft ellipses. Position and radii are fractions of
    /// the stage, the way the stylesheet states them; the colour runs out at 70%
    /// of the radius, as `transparent 70%` does.
    private func glow(at unit: NSPoint, radii: NSSize, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rx = bounds.width * radii.width
        let ry = bounds.height * radii.height
        guard rx > 0, ry > 0 else { return }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 0.7]) else { return }

        ctx.saveGState()
        // Circular gradients only, so the ellipse comes from squashing the space
        // it is drawn in — the same trick the reveal's mask uses.
        ctx.translateBy(x: bounds.width * unit.x, y: bounds.height * unit.y)
        ctx.scaleBy(x: 1, y: ry / rx)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: rx, options: [])
        ctx.restoreGState()
    }

    /// A window with something to read in it, sitting on the desktop with the
    /// same air above it as below.
    private func drawWindow(_ palette: DesktopPalette) {
        let margin: CGFloat = 42
        let width = ((bounds.width - 300) * 0.9).rounded()
        let frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: margin,
                           width: width, height: bounds.height - margin * 2)
        guard frame.width > 0, frame.height > 0 else { return }
        let radius: CGFloat = 12
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(palette.shadow)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        palette.window.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        // Title bar: the same two-stop wash the demo's windows wear, and a
        // hairline where it ends rather than a line drawn under it.
        let bar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        // Drawn upwards, so `starting` is the bottom edge and `ending` the top.
        NSGradient(starting: palette.ink.withAlphaComponent(palette.barBottom),
                   ending: palette.ink.withAlphaComponent(palette.barTop))?.draw(in: bar, angle: 90)
        // The value that gradient ends on, so the divider is one more row of it
        // rather than a line drawn under it.
        palette.ink.withAlphaComponent(palette.line).setFill()
        NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1).fill()

        for (i, colour) in [
            NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),      // #ff5f57
            NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),  // #febc2e
            NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),  // #28c840
        ].enumerated() {
            colour.setFill()
            let light = NSRect(x: frame.minX + 20 + CGFloat(i) * 20, y: bar.midY - 6,
                               width: 12, height: 12)
            NSBezierPath(ovalIn: light).fill()
        }

        // Something to read through the hole. Fixed widths rather than random:
        // this repaints whenever the stage resizes, and a page that reshuffles
        // itself while the window is being dragged would be a page of confetti.
        let widths: [CGFloat] = [0.62, 0.88, 0.74, 0.93, 0.51, 0.82, 0.68, 0.90, 0.58]
        let inset: CGFloat = 34
        var y = bar.minY - 26
        var i = 0
        palette.ink.withAlphaComponent(palette.content).setFill()
        while y > frame.minY {
            let w = (frame.width - inset * 2) * widths[i % widths.count]
            let line = NSRect(x: frame.minX + inset, y: y, width: w, height: 7)
            NSBezierPath(roundedRect: line, xRadius: 3.5, yRadius: 3.5).fill()
            y -= 20
            i += 1
        }

        // The frame, drawn over its own contents: a hairline is what says where
        // the window ends against a wallpaper of about the same weight.
        palette.edge.setStroke()
        let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Preview

final class SettingsPreview: NSView {
    /// Tall enough for the live box and two or three of the stack above it.
    static let displayHeight: CGFloat = 164

    private let stage = PreviewStage()
    private let box = SubtitleView(frame: .zero)
    /// The stack, in the same scroll view the overlay puts it in — so it
    /// overflows, scrolls and fades at the clipped edge the way the real one
    /// does rather than simply running out of room.
    private let scroll = HistoryScrollView()
    private let document = NSView()
    /// Softens the edge with content beyond it. A mask on the clip view rather
    /// than a gradient drawn over the top, for the reason `HistoryController`
    /// gives: there is no colour to fade to over the picture behind.
    private let fadeMask = CAGradientLayer()
    private var boundsObserver: NSObjectProtocol?
    /// Height of the whole stack and of the room it was last given, so a box
    /// closing under a reader who has scrolled back can be anchored against
    /// both.
    private var contentHeight: CGFloat = 0
    private var placedHeight: CGFloat = 0
    private var pills: [HistoryPillView] = []
    /// The texts currently laid out, so a box that was already up when another
    /// one closed does not animate in a second time.
    private var laidOut: [String] = []
    /// What the pills were built from, so nine ticks a second do not rebuild
    /// half a dozen views that have not changed.
    private var pillKey = ""

    private var style = PreviewStyle()

    /// Gap between boxes in the stack, matching `HistoryController`.
    private static let gap: CGFloat = 6
    /// Air between the pill and the edges of the stage.
    private static let margin: CGFloat = 26
    /// Ceiling on the fade at the clipped edge, matching `HistoryController`:
    /// it grows with the amount actually hidden, so a stack overflowing by ten
    /// points gets a ten-point fade rather than swallowing a whole box.
    private static let fadeHeight: CGFloat = 150

    // ── what is on the box ──
    private var page = ""
    private var tentative = ""
    /// One box to start with, and the loop adds to it from there. Seeded rather
    /// than started empty because someone who opens this window and drags Keep
    /// must have something to bring back on the first drag, and waiting for the
    /// loop to close a box of its own would show an empty screen at exactly the
    /// moment the control is being asked what it does.
    private var closed: [String] = Array(SettingsPreview.script.prefix(1))

    // ── the scripted loop ──
    /// Starts after the seeded box, so the loop reads as one continuous run
    /// rather than repeating what is already in the stack.
    private var scriptIndex = 1
    private var wordIndex = 0
    private var holdTicks = 0
    private var tick: Timer?
    private static let interval: TimeInterval = 0.11

    /// A sentence about the control being dragged, and how long it stays up
    /// after the last edit.
    private var focusText: String?
    private var focusUntil = Date.distantPast
    private static let focusGrace: TimeInterval = 3.5

    /// While a reveal control is being dragged the pointer is on the slider, not
    /// over the box, so there is no hole to look at. Park one in the middle of
    /// the box for as long as the sentence is up.
    private var parkReveal = false

    private var pointer: NSPoint?

    /// The stack is down by default, exactly as it is on the overlay, and comes
    /// up for as long as something is asking for it: a Recent Boxes control
    /// being touched, or ⌥ held.
    private var stackUntil = Date.distantPast
    private var isStackUp = false
    /// Nothing raises the stack before this. A window being built is a flurry
    /// of controls being given their values, and any of that which reached
    /// `explain` would put the stack up on a window the user has only just
    /// opened. Cheaper than proving no such path exists today and staying sure
    /// of it as rows are added.
    private var settledAt = Date.distantPast
    private static let settle: TimeInterval = 0.4

    /// ⌥ has been seen up since this preview appeared.
    ///
    /// Without it the stack can be up the moment the window opens: Settings is
    /// reached from a menu, and a modifier still held from whatever was done
    /// over that menu would read as the gesture. Nothing the user has not asked
    /// for since the window appeared may raise it.
    private var sawOptionReleased = false

    /// Lines the box types out when nothing is playing. Written to be worth
    /// reading once: each says something true about the thing above it, and
    /// they are of deliberately different lengths so the line limit has
    /// something to page.
    private static let script = [
        "Play something and these become the real captions, live.",
        "A box fills to the line limit, then clears and starts the next one. It never scrolls.",
        "Point anywhere in here and the box dissolves under the pointer, so you can read through it.",
        "Finished boxes are kept. Hold ⌥ here, or over the overlay, and they stack back up.",
        "All of it runs on this Mac. Nothing is recorded and nothing is sent anywhere.",
    ]

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Decorative through and through — a scripted loop and drawings of
        // boxes. The rows underneath say all of this in words, and that is what
        // VoiceOver should be reading.
        setAccessibilityElement(false)
        setAccessibilityRole(.unknown)

        // Rounded out here rather than on the stage, and this is not a detail:
        // the stage's layer is scaled with its bounds, so a radius set there is
        // in overlay points and comes out at a third of itself — which is how
        // the corners ended up all but square. This view is unscaled, so 16
        // points is 16 points, near enough the 20 the site demo wears at its own
        // width. The hairline is that demo's frame, for the same reason it has
        // one: at this weight the screen and the window behind the settings need
        // an edge between them.
        layer?.masksToBounds = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        applyFrameColour()

        stage.wantsLayer = true
        // Boxes that run off the top are clipped rather than hidden, which is
        // how the stack says there is more above than there is room for — the
        // same thing the overlay's fade gradient says.
        stage.layer?.masksToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.onResize = { [weak self] in self?.relayout() }
        addSubview(stage)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Lifted whole from HistoryController.init: no scroller (the fade at the
        // clipped edge is what says there is more), no background, no automatic
        // insets — an inset clip view is a fade over content that is not
        // actually clipped.
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.contentView.wantsLayer = true
        scroll.alphaValue = 0
        scroll.isHidden = true

        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: nil
        ) { [weak self] _ in
            self?.updateFade()
        }

        // Below the live box, so a sentence growing to three lines rides over
        // the stack rather than being hidden behind it.
        stage.addSubview(scroll)
        stage.addSubview(box, positioned: .above, relativeTo: scroll)
        beginLine()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A `CGColor` on a layer is a fixed colour and does not follow anything, so
    /// the frame is the one thing here that has to be told.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFrameColour()
    }

    private func applyFrameColour() {
        layer?.borderColor = DesktopPalette.matching(effectiveAppearance).edge.cgColor
    }

    // MARK: lifecycle

    /// The window is torn down and rebuilt on every open, and again on a reset.
    /// Driving the timer from the view's own window membership is what stops a
    /// discarded preview from ticking on in the background.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tick?.invalidate()

        // Down, now, and not merely "will be lowered on the next tick". This
        // runs whenever the preview enters or leaves a window, which includes
        // being put back after a trip to the Models pane — and a stack that was
        // up when it left is otherwise still up when it returns, because
        // `isStackUp` travels with the view. Nothing may be showing that the
        // user has not asked for since this window appeared in front of them.
        isStackUp = false
        scroll.isHidden = true
        scroll.alphaValue = 0
        stackUntil = .distantPast
        sawOptionReleased = false
        settledAt = Date().addingTimeInterval(Self.settle)

        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.step()
        }
        // `.common`, or the loop stops for as long as a slider is held down —
        // which is exactly when someone is watching it.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    deinit {
        tick?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    // MARK: input

    /// The settings the rows are currently showing. Applied whole; the caller
    /// re-reads the getters after every edit.
    func apply(_ new: PreviewStyle) {
        guard new != style else { return }
        style = new
        relayout()
    }

    /// Say what the control being dragged does, with its value in the sentence.
    ///
    /// Two things come with it, for the two settings that describe something not
    /// currently on screen. The Recent Boxes controls raise the stack, because a
    /// number for how many boxes ⌥ keeps means nothing next to a screen with no
    /// stack on it. The reveal controls park a hole in the middle of the box,
    /// because the pointer that would otherwise be punching one is busy holding
    /// the slider.
    func explain(_ topic: PreviewTopic) {
        focusUntil = Date().addingTimeInterval(Self.focusGrace)
        parkReveal = topic == .reveal && style.revealEnabled
        switch topic {
        case .keep, .dimness, .expiry:
            // Not while settling: a control being given its value as the window
            // is built is not somebody touching it.
            if Date() > settledAt { stackUntil = focusUntil }
        case .lines, .background, .reveal:
            break
        }
        // Immediately, not on the next tick: the sentence is the answer to a
        // gesture that is happening now.
        focusText = sentence(for: topic)
        page = focusText ?? ""
        tentative = ""
        relayout()
    }

    private func sentence(for topic: PreviewTopic) -> String {
        func pct(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }

        switch topic {
        case .lines:
            return style.maxLines == 1
                ? "One line to a box. It clears and starts again on the next word that will not fit."
                : "\(style.maxLines) lines to a box, then it clears and the next one starts."
        case .background:
            return style.boxOpacity < 0.02
                ? "No pill at all. Bare text over the picture, the way some players draw subtitles."
                : "The pill behind the text is \(pct(style.boxOpacity)) solid."
        case .reveal:
            guard style.revealEnabled else {
                return "The box stays solid under the pointer. Move it instead: hold ⇧ and drag."
            }
            return "Point at the box and this much of it dissolves, this far around the pointer."
        case .keep:
            guard style.historyEnabled, style.historyDepth > 0 else {
                return "⌥ brings nothing back. Finished boxes are gone once they clear."
            }
            return style.historyDepth == 1
                ? "⌥ brings back the last box."
                : "⌥ brings back the last \(style.historyDepth) boxes, newest first, and scrolls through them."
        case .dimness:
            return "The stack's text sits at \(pct(style.historyTextOpacity)) against the live box's white."
        case .expiry:
            guard style.historyExpires else {
                return "The stack is kept until you pause or quit."
            }
            let s = Int(style.historyExpiry.rounded())
            let quiet = s % 60 == 0 && s >= 60
                ? "\(s / 60) minute\(s == 60 ? "" : "s")"
                : "\(s) second\(s == 1 ? "" : "s")"
            return "After \(quiet) with nothing said, the stack is forgotten."
        }
    }

    // MARK: the loop

    private func step() {
        updateMask()
        syncStack()

        if focusText != nil {
            if Date() < focusUntil { return }
            focusText = nil
            parkReveal = false
            beginLine()
        }

        if holdTicks > 0 {
            holdTicks -= 1
            if holdTicks == 0 {
                close(page)
                scriptIndex = (scriptIndex + 1) % Self.script.count
                beginLine()
            }
            relayout()
            return
        }

        let words = Self.script[scriptIndex].split(separator: " ").map(String.init)
        guard wordIndex < words.count else {
            // Read it before it goes.
            holdTicks = 16
            return
        }

        let word = words[wordIndex]
        wordIndex += 1

        // The same rule the overlay pages by, measured by the same code: if the
        // next word would push past the line limit, the box closes and the new
        // one starts from that word.
        let grown = page.isEmpty ? word : page + " " + word
        if !page.isEmpty,
           box.lineCount(committed: grown, tentative: "", width: ceiling) > style.maxLines {
            close(page)
            page = word
        } else {
            page = grown
        }
        relayout()
    }

    private func beginLine() {
        wordIndex = 0
        holdTicks = 0
        page = ""
        tentative = ""
    }

    private func close(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != closed.last else { return }
        closed.append(trimmed)
        // Kept well past any depth the slider can ask for, so dragging Keep
        // upwards has boxes to add rather than filling one per sentence.
        if closed.count > 40 { closed.removeFirst(closed.count - 40) }
    }

    // MARK: layout

    private var ceiling: CGFloat { max(120, stage.bounds.width - Self.margin * 2) }

    private func relayout() {
        box.fontSize = style.fontSize
        box.maxLines = style.maxLines
        box.backgroundOpacity = style.boxOpacity
        box.maskStrength = style.revealOpacity
        box.maskSize = style.revealSize
        box.committed = page
        box.tentative = tentative

        let size = box.fittingSize(maxWidth: ceiling)
        box.isHidden = size.height <= 0
        let bottom = Self.margin - SubtitleView.pad
        box.frame = NSRect(x: ((stage.bounds.width - size.width) / 2).rounded(),
                           y: bottom.rounded(),
                           width: size.width, height: size.height)

        layoutStack(above: box.frame.maxY - SubtitleView.pad)
        syncStack()
        updateMask()
    }

    /// Build the stack, and frame the scroll view against the live box.
    ///
    /// The document holds every box the depth allows, not only the ones that
    /// fit: what does not fit is what the wheel is for.
    private func layoutStack(above top: CGFloat) {
        let depth = style.historyEnabled ? style.historyDepth : 0
        // Newest first, so index 0 is the box against the live one — which is
        // where the eye goes, so where the animation starts and where the scroll
        // parks.
        let visible = Array(closed.suffix(depth).reversed())

        let pillStyle = HistoryStyle(
            fontSize: style.fontSize,
            maxLines: style.maxLines,
            // Stepped back from the live box exactly as the overlay steps it, so
            // dragging Background moves both and keeps the stack behind it.
            fill: style.boxOpacity * HistoryPillView.recession,
            textOpacity: style.historyTextOpacity)

        let key = "\(visible.joined(separator: "\u{1}"))|\(pillStyle.fontSize)|\(pillStyle.maxLines)"
            + "|\(pillStyle.fill)|\(pillStyle.textOpacity)|\(ceiling)"
        if key != pillKey {
            pillKey = key
            rebuild(visible, style: pillStyle)
        }

        // Room between the live box and the top of the stage. The live box grows
        // upwards as a sentence wraps, so this shrinks under it — which is why
        // the height is re-derived here rather than set once.
        let bottom = top + Self.gap
        let room = max(0, stage.bounds.height - bottom)
        let resized = abs(room - placedHeight) > 0.5
        placedHeight = room
        scroll.frame = NSRect(x: 0, y: bottom.rounded(),
                              width: stage.bounds.width, height: room.rounded())
        if resized { park() }
        updateFade()
    }

    /// Lay the boxes out from the edge that touches the live box, and hold the
    /// reader where they were.
    private func rebuild(_ visible: [String], style pillStyle: HistoryStyle) {
        // Where the reader is, measured from the newest box, before any of this
        // changes underneath them.
        let previousContent = contentHeight
        let previousNear = scroll.contentView.bounds.origin.y
        let wasParked = !isStackUp || previousNear <= 1

        // Boxes that were already up keep their place and do not animate again —
        // the same rule the overlay's stack follows.
        let carried = Set(laidOut)
        pills.forEach { $0.removeFromSuperview() }
        pills = []
        laidOut = []
        var fresh: [HistoryPillView] = []

        var sizes: [NSSize] = []
        for text in visible {
            let pill = HistoryPillView(text: text, style: pillStyle)
            sizes.append(pill.fittingSize(maxWidth: ceiling))
            pills.append(pill)
            laidOut.append(text)
            if !carried.contains(text) { fresh.append(pill) }
        }

        contentHeight = sizes.reduce(0) { $0 + $1.height }
            + Self.gap * CGFloat(max(pills.count - 1, 0))
        document.frame = NSRect(x: 0, y: 0, width: stage.bounds.width, height: contentHeight)

        // Document coordinates are y-up and the stack sits above the live box, so
        // the newest box is laid at the bottom and the older ones climb away.
        var offset: CGFloat = 0
        for (i, pill) in pills.enumerated() {
            let size = sizes[i]
            pill.frame = NSRect(x: ((stage.bounds.width - size.width) / 2).rounded(),
                                y: offset.rounded(), width: size.width, height: size.height)
            document.addSubview(pill)
            offset += size.height + Self.gap
        }

        // Stick to the newest box if that is where the reader already was, so a
        // page closing brings the new box into view. If they had scrolled back to
        // an older one, hold that box still instead — never mid-flick, where a
        // correction fights the elastic bounce and reads as a stutter.
        if !scroll.isScrolling {
            setNear(wasParked ? 0 : previousNear + (contentHeight - previousContent))
        }

        // A page closing while the stack is up joins it there and then.
        if isStackUp, !fresh.isEmpty, fresh.count < pills.count { animateIn(fresh) }
    }

    private var maxScrollOffset: CGFloat {
        max(0, contentHeight - scroll.contentView.bounds.height)
    }

    private func park() {
        guard !scroll.isScrolling else { return }
        setNear(scroll.contentView.bounds.origin.y)
    }

    /// Distance from the edge that touches the live box, clamped to what there
    /// is to scroll.
    private func setNear(_ distance: CGFloat) {
        let offset = min(max(distance, 0), maxScrollOffset)
        guard abs(offset - scroll.contentView.bounds.origin.y) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Fade the clipped edge in proportion to what is behind it.
    ///
    /// Driven by the clip view's bounds notification as well as by layout, so it
    /// tracks the wheel rather than only the moment the stack is built.
    private func updateFade() {
        let clip = scroll.contentView
        let visible = clip.bounds
        let hidden = contentHeight - visible.maxY

        // Nothing behind that edge — including the case where the whole stack
        // fits. A fade with nothing behind it promises more and does not deliver.
        guard visible.height > 0, contentHeight > visible.height + 1, hidden > 0.5 else {
            if clip.layer?.mask != nil { clip.layer?.mask = nil }
            return
        }

        let fade = min(min(Self.fadeHeight, hidden), visible.height / 2)
        let stop = fade / visible.height

        // No implicit animation: this is recomputed on every scroll event, and
        // CoreAnimation's default quarter-second interpolation would leave the
        // fade lagging visibly behind the content.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The mask lives in the clip view's own coordinates, whose origin *is*
        // the scroll offset — so tracking `bounds` is what keeps it still while
        // the content moves under it.
        fadeMask.frame = visible
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        let clear = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor
        fadeMask.colors = [solid, solid, clear]
        fadeMask.locations = [0, NSNumber(value: Double(1 - stop)), 1]
        if clip.layer?.mask !== fadeMask { clip.layer?.mask = fadeMask }
        CATransaction.commit()
    }

    // MARK: raising the stack

    /// ⌥ down, with this window the one in front.
    ///
    /// Polled rather than monitored, for the reason the overlay polls it: a
    /// keyboard monitor would demand Accessibility permission, and one is not
    /// being asked for to animate a preview.
    private var optionHeld: Bool {
        window?.isKeyWindow == true && NSEvent.modifierFlags.contains(.option)
    }

    /// Up while something is asking for it.
    private func wantsStack() -> Bool {
        let held = optionHeld
        // ⌥ already down when the window opened is not a request: Settings is
        // reached from a menu, and a modifier still held from whatever was done
        // over that menu would read as the gesture.
        if !held { sawOptionReleased = true }
        guard style.historyEnabled, style.historyDepth > 0, !pills.isEmpty,
              Date() > settledAt else { return false }
        if held, sawOptionReleased { return true }
        return Date() < stackUntil
    }

    private func syncStack() {
        let want = wantsStack()
        guard want != isStackUp else { return }
        isStackUp = want

        guard want else {
            // The overlay fades the whole panel rather than each box; so does
            // this, which is why the pills live in a scroll view of their own.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                scroll.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Hidden, not merely transparent: a view at zero alpha still
                // takes the wheel, and an invisible stack swallowing scrolls
                // over the preview would be a puzzle.
                guard let self, !self.isStackUp else { return }
                self.scroll.isHidden = true
            })
            return
        }
        scroll.isHidden = false
        scroll.alphaValue = 1
        setNear(0)
        animateIn(pills)
    }

    /// Boxes rise out of the live one, nearest first — the same 35 ms stagger,
    /// 12 points of displacement and 0.22 s ease as `HistoryController`, because
    /// this is meant to be a rehearsal of that gesture and not a similar one.
    ///
    /// The displacement is in stage points, so it scales with everything else:
    /// twelve points of travel on a box a third the size would be a lurch.
    private func animateIn(_ rising: [HistoryPillView]) {
        let now = CACurrentMediaTime()
        for (i, pill) in rising.enumerated() {
            guard let layer = pill.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1

            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -12
            slide.toValue = 0

            for animation in [fade, slide] {
                animation.duration = 0.22
                animation.beginTime = now + Double(i) * 0.035
                // Holds each box invisible until its turn; without it they all
                // sit at full opacity until their start time and the stack
                // flashes in before it animates.
                animation.fillMode = .backwards
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: animation.keyPath)
            }
        }
    }

    // MARK: the reveal

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        updateMask()
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        updateMask()
    }

    override func mouseEntered(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        updateMask()
    }

    private func updateMask() {
        // ⌥ closes the hole, exactly as it does on the overlay: the pointer is
        // over the stack to scroll it, and a hole punched through the live box
        // underneath while the user is reading the history above it is noise.
        guard style.revealEnabled, !optionHeld else {
            box.maskCenter = nil
            return
        }
        if let pointer {
            box.maskCenter = box.convert(pointer, from: self)
        } else if parkReveal, Date() < focusUntil {
            box.maskCenter = NSPoint(x: box.bounds.midX, y: box.bounds.midY)
        } else {
            box.maskCenter = nil
        }
    }

    // MARK: scale

    /// Overlay points across the stage. The same width the overlay allows itself
    /// on this screen, so a box that would fill two thirds of the display fills
    /// two thirds of the preview.
    private static var stageWidth: CGFloat {
        guard let screen = NSScreen.main else { return 900 }
        return min(screen.frame.width * 0.7, 1100)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        stage.contentScale = bounds.width / Self.stageWidth
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.displayHeight)
    }
}
