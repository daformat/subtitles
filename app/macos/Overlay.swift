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
import CaptionCore

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
    /// The original under a translation, when both languages are shown: a
    /// second paragraph beneath the caption in a smaller, dimmer run. Empty
    /// when there is nothing to pair the caption with. Not part of `lineCount`,
    /// so paging is decided on the caption alone and the box grows for it.
    var secondary = "" { didSet { if secondary != oldValue { needsDisplay = true } } }
    /// The unsettled tail of the paragraph under the caption, dimmed the way
    /// the caption's own is — the same fraction of its run's strength — when
    /// that paragraph is the translation. Follows the translation timing
    /// setting exactly as the caption does, since it is the same emission.
    var secondaryTentative = "" { didSet { if secondaryTentative != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat = 30 { didSet { needsDisplay = true } }

    /// The Text Size menu's steps, smallest first.
    static var textSizes: [(label: String, size: CGFloat)] {
        [(L("text size|Small"), 22), (L("text size|Medium"), 30),
         (L("text size|Large"), 40), (L("text size|Huge"), 52)]
    }

    /// Below Small, for the history at Small: not offered in the menu, only
    /// as the step the stack comes down to.
    static let historyFloorSize: CGFloat = 17

    /// The ⌥ history's boxes, one step down from the live box's size so the
    /// stack reads as behind it; at Small, the step is `historyFloorSize`.
    /// A size between steps comes down to the largest step under it.
    static func historyFontSize(for size: CGFloat) -> CGFloat {
        let steps = [historyFloorSize] + textSizes.map(\.size)
        guard let index = steps.lastIndex(where: { $0 <= size + 0.5 }), index > 0 else {
            return min(size, historyFloorSize)
        }
        return steps[index - 1]
    }

    /// The original's type against the caption's: smaller and a little
    /// lighter, so the caption stays the line being read and the original
    /// the note under it — the way dual subtitles are set.
    static let secondaryScale: CGFloat = 0.8
    static let secondaryOpacity: CGFloat = 0.75
    var secondaryFontSize: CGFloat { fontSize * Self.secondaryScale }
    /// Between the caption's last line and the original's first.
    static func secondaryGap(for size: CGFloat) -> CGFloat { (size * 0.35).rounded() }
    private var secondaryGap: CGFloat { Self.secondaryGap(for: fontSize) }

    /// The icon of the app whose audio is on screen, or nil for text alone,
    /// and the app's name for the styles that show it. Where it goes is
    /// `iconStyle`; the box makes room for it — see Pill.
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    var appName: String? {
        didSet { if appName != oldValue { needsDisplay = true } }
    }
    var iconStyle: Pill.IconStyle = .header {
        didSet { if iconStyle != oldValue { needsDisplay = true } }
    }

    /// How the text sits in the box — see `Pill.TextAlignment`. Changes no
    /// measurement: the box hugs its widest line either way.
    var textAlignment: Pill.TextAlignment = .start {
        didSet { if textAlignment != oldValue { needsDisplay = true } }
    }

    /// What the icon takes around the pill right now.
    private var iconRoom: Pill.IconRoom {
        Pill.room(iconStyle, size: fontSize, icon: icon != nil, name: appName)
    }

    /// The text's direction, from its first strong character: what natural
    /// alignment lays it out by, and which edge the icon sits at.
    private var isRightToLeft: Bool {
        Pill.isRightToLeft(committed.isEmpty ? tentative : committed)
    }

    private var squareCorners: Set<Pill.Corner> {
        Pill.squareCorners(style: iconStyle, icon: icon != nil, rtl: isRightToLeft)
    }

    /// The tab for the blur to cover, when there is one.
    private func blurTab(on pill: NSRect, rtl: Bool) -> BackdropBlurView.Shape.Tab? {
        guard icon != nil, iconStyle == .nameTab else { return nil }
        return .init(rect: Pill.tabRect(on: pill, name: appName, size: fontSize, rtl: rtl), rtl: rtl)
    }

    /// The box's colors follow the appearance, which is the theme's: see
    /// `Pill.Theme`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Draws the dashed ring that says the box can be picked up right now. Set
    /// while ⇧ is held, alongside the panel dropping its click-through.
    var showsDragOutline = false { didSet { needsDisplay = true } }
    /// Text in the caption drawn as a link, and what a click on the box does
    /// while it shows. Only the app's own last line has one; the transcript
    /// never does, and the panel passes clicks through whenever this is nil.
    var link: (text: String, open: () -> Void)? {
        didSet {
            needsDisplay = true
        }
    }

    // The panel is never key, so cursor rects do not apply there: a tracking
    // area that is always active sets the hand instead.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.cursorUpdate) }) {
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeAlways, .cursorUpdate, .inVisibleRect],
                                           owner: self))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if link != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    // The first click in a panel that never becomes key has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { link != nil }

    // A click on the link is a click, not the start of a drag.
    override var mouseDownCanMoveWindow: Bool { link == nil }

    override func mouseDown(with event: NSEvent) {
        if link == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let link, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseUp(with: event)
            return
        }
        link.open()
    }

    /// The borealis's frame to paint along the bottom of the pill; nil
    /// paints none. See AudioBorealis.
    var borealis: AudioBorealis.Frame? {
        didSet { if borealis != oldValue { needsDisplay = true } }
    }

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

    /// The blur under the pill, when there is one: a sibling beneath this view,
    /// told the pill's shape on every draw — hole included — so what it
    /// softens is exactly what the pill covers, and no more once the reveal
    /// has opened the box.
    weak var backdrop: BackdropBlurView?

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

    /// The pill itself, inside that margin and the icon's room.
    private var boxRect: NSRect { Pill.pillRect(in: bounds, pad: Self.pad, room: iconRoom) }

    /// Committed text at full strength, the in-flight tail dimmed.
    ///
    /// Spike 0A measured this engine as effectively non-revising (0 ms p50 commit
    /// lag, 4 of 66 words ever revised), so in practice the dimmed tail is usually
    /// empty. It stays because it costs nothing and is what makes a revising
    /// engine survivable if the model is ever swapped.
    func attributed(committed: String, tentative: String,
                    measuring: Bool = false) -> NSAttributedString {
        let text = Pill.attributed(committed: committed, tentative: tentative,
                                   size: fontSize, measuring: measuring, alignment: textAlignment)
        // Underlined, which changes no metric: the box measures the same.
        guard let link, !measuring else { return text }
        let range = (text.string as NSString).range(of: link.text)
        guard range.location != NSNotFound else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        return out
    }

    private func metrics(committed: String, tentative: String,
                         maxWidth: CGFloat) -> (used: NSSize, lines: Int) {
        Pill.metrics(attributed(committed: committed, tentative: tentative, measuring: true),
                     textWidth: maxWidth - (inset.width + Self.pad) * 2)
    }

    func lineCount(committed: String, tentative: String, width: CGFloat) -> Int {
        metrics(committed: committed, tentative: tentative, maxWidth: width).lines
    }

    func attributedSecondary(_ text: String, tentative: String = "",
                             measuring: Bool = false) -> NSAttributedString {
        Pill.attributed(committed: text, tentative: tentative, size: secondaryFontSize,
                        measuring: measuring, opacity: Self.secondaryOpacity,
                        alignment: textAlignment)
    }

    func secondaryLineCount(_ text: String, width: CGFloat) -> Int {
        Pill.metrics(attributedSecondary(text, measuring: true),
                     textWidth: width - (inset.width + Self.pad) * 2).lines
    }

    /// The original's block under the caption: the height it adds, gap
    /// included and capped at `maxLines` of its own size, and the width it
    /// hugs. nil with no original to draw.
    private func secondaryBlock(maxWidth: CGFloat) -> (height: CGFloat, width: CGFloat)? {
        guard !(secondary.isEmpty && secondaryTentative.isEmpty) else { return nil }
        let m = Pill.metrics(attributedSecondary(secondary, tentative: secondaryTentative,
                                                 measuring: true),
                             textWidth: maxWidth - (inset.width + Self.pad) * 2)
        guard m.lines > 0 else { return nil }
        let capped = min(m.used.height,
                         Pill.lineHeight(ofSize: secondaryFontSize) * CGFloat(maxLines) + 4)
        return (secondaryGap + ceil(capped), m.used.width + 2 + (inset.width + Self.pad) * 2)
    }

    /// Size the box needs, hugging its content.
    ///
    /// `maxWidth` is a ceiling, not the width: a short line gets a short box.
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        var size = Pill.fittingSize(attributed(committed: committed, tentative: tentative,
                                               measuring: true),
                                    size: fontSize, maxWidth: maxWidth,
                                    maxLines: maxLines, pad: Self.pad, room: iconRoom)
        // The original under the caption adds its block: the box is as tall as
        // both and as wide as the wider.
        if size.height > 0, let block = secondaryBlock(maxWidth: maxWidth) {
            size.height += block.height
            size.width = min(max(size.width, block.width), maxWidth)
        }
        return size
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

    /// The blur wears the pill's shape. None at all with no text, and none at
    /// zero: that setting says bare text over the picture, and a softened
    /// rectangle behind bare text is a pill by another name.
    private func syncBackdrop(drawsPill: Bool) {
        guard let backdrop else { return }
        guard drawsPill, backgroundOpacity > 0 else {
            backdrop.shape = nil
            return
        }
        let rtl = isRightToLeft
        backdrop.shape = .init(rect: boxRect, corner: corner, hole: maskCenter.map {
            .init(center: $0, size: maskSize, strength: maskStrength)
        }, square: squareCorners, tab: blurTab(on: boxRect, rtl: rtl))
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributed(committed: committed, tentative: tentative)
        // Here, because everything the shape depends on ends in a redraw: this
        // is the one place the blur is certain to be told with the pill.
        syncBackdrop(drawsPill: text.length > 0)
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
        let rtl = isRightToLeft
        Pill.box.withAlphaComponent(backgroundOpacity).setFill()
        Pill.pillPath(box, radius: corner, square: squareCorners).fill()
        // The tab's fill goes down with the pill's, so what is painted over
        // the box runs into the tab too; its line, icon and name come later,
        // over that.
        let wearsTab = icon != nil && iconStyle == .nameTab
        if wearsTab, backgroundOpacity > 0 {
            Pill.fillTab(on: box, name: appName, size: fontSize, fill: backgroundOpacity, rtl: rtl)
        }
        // The glow, over the box and under everything on it, inside its whole
        // silhouette, tab included. With no pill there is no edge to sit on.
        if let borealis, backgroundOpacity > 0, let ctx {
            AudioBorealisPainter.draw(borealis, in: ctx, pill: box,
                                      path: Pill.silhouette(pill: box, style: iconStyle, icon: icon != nil,
                                                            name: appName, size: fontSize, rtl: rtl, grow: 0),
                                      fontSize: fontSize)
        }
        // No pill, no outline: at zero the setting says bare text over the picture.
        let scale = window?.backingScaleFactor ?? 2
        if backgroundOpacity > 0 {
            Pill.outline(pill: box, style: iconStyle, icon: icon != nil, name: appName,
                         size: fontSize, rtl: rtl, scale: scale)
        }

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
            // Around the pill and its tab, not the panel: the icon's room is
            // outside it, and a tab is part of the shape being picked up.
            let ring = Pill.silhouette(pill: box, style: iconStyle, icon: icon != nil, name: appName,
                                       size: fontSize, rtl: rtl, grow: Self.pad - 0.5)
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

        // Inside the transparency layer with the rest, so the reveal opens
        // through the icon as it does through the text.
        if let icon {
            Pill.draw(icon: icon, name: appName, style: iconStyle, on: box,
                      size: fontSize, fill: backgroundOpacity, rtl: rtl, scale: scale, filled: false)
        }
        let textRect = Pill.textRect(in: box, room: iconRoom)
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // The original, in the room `fittingSize` added under the caption: the
        // bottom of the text rect, the gap above it left empty.
        if let block = secondaryBlock(maxWidth: bounds.width) {
            let under = NSRect(x: textRect.minX, y: textRect.minY,
                               width: textRect.width, height: block.height - secondaryGap)
            attributedSecondary(secondary, tentative: secondaryTentative)
                .draw(with: under, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }
}

// MARK: - Controller

final class OverlayController {
    private let panel: SubtitlePanel
    private let view: SubtitleView
    /// Under the view, filling the panel with it — see BackdropBlur.swift.
    private let backdrop = BackdropBlurView(blending: .behindWindow)
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

    /// A page turn held back for reading — see `holdPage(after:)`: until when
    /// the page on screen stays, whatever the pager has moved on to.
    private var holdUntil: Date?
    private var holdTimer: Timer?
    /// The next draw is a new page, and dates `displayedPageSince`.
    private var pendingPageChange = false
    /// When the page on screen was first drawn: how long it has been readable.
    private var displayedPageSince = Date.distantPast
    /// Characters a second a reader gets through at the caption's size — 17,
    /// the upper end of what subtitle guidelines allow, since a reader here
    /// has been following the words as they came rather than meeting a full
    /// box cold. Characters rather than words: it is the rendered text that
    /// takes reading, and a word is a different amount of it in French, in
    /// German and in Japanese. Text drawn smaller reads slower in proportion.
    private let readingRate: Double = 17
    /// The most a page may be held for. The hold is only what the reader is
    /// still owed, so it is usually a fraction of this. A second, tried at
    /// two: every hold puts the caption that much further behind the speaker,
    /// and two read as the box lagging rather than as time to finish it.
    private let maxHold: TimeInterval = 1
    /// `SUBS_DEBUG_PAGING=1` reports each hold, mirroring SUBS_DEBUG_TRANSLATE.
    private static let debugPaging = ProcessInfo.processInfo.environment["SUBS_DEBUG_PAGING"] != nil

    /// The last clause boundary a page break carried from.
    ///
    /// A clause is carried into the *next* box and no further. When nothing new
    /// settles behind it the box can fill and turn over on the growing tail alone,
    /// and that same boundary is still the newest one in reach, so without this it
    /// is carried again and again and opens box after box. Recording it means the
    /// carry can only ever move forwards.

    /// The box has been emptied and is showing nothing: it faded out, or a switch
    /// cleared it.
    ///
    /// The stored transcripts outlive the box, which is what lets ⌃ swap language
    /// instantly, and it also meant ⌃ could redraw a box that had already faded
    /// and hand back a caption the reader had finished with. A repaint is not new
    /// speech, so it does not bring the box back; the next words do.
    private var boxIsCleared = false

    /// Set while a repaint is only swapping the stack's language, so it is
    /// replaced in place rather than staged in again.
    private var isSwappingLanguage = false

    /// Whether the page about to close is one worth carrying a clause from.
    ///
    /// Two rules, and the first is absolute: a box that has faded is never carried
    /// from. Whatever was in it is gone from the screen and from the reader, so
    /// repeating its last clause is not continuity, it is old text taking up the
    /// top of a box that should be showing what is being said now. `boxIsCleared`
    /// is still set while the first words after a fade are being paged, which is
    /// what keeps that first new box clean.
    ///
    /// Second, a box that sat there as long as the fade would have allowed has
    /// already given the reader that time, so there is nothing to hand back.
    private var allowsCarry: Bool {
        guard !boxIsCleared else { return false }
        return Date().timeIntervalSince(pageShownAt) < textIdleTimeout
    }
    private var isDraggable = false

    /// How solid the box behind the text is, 0…1. The ⌥ stack follows it, a step
    /// behind — see `HistoryPillView.recession`.
    var boxOpacity: CGFloat {
        get { view.backgroundOpacity }
        set { view.backgroundOpacity = newValue }
    }

    /// How far the picture behind the box is softened, in points; 0 is not at
    /// all. The ⌥ stack takes the same number: unlike the fill there is no
    /// stepping back to do, since a softer picture is a softer picture.
    var backdropBlur: CGFloat = Pill.backdropBlur {
        didSet { backdrop.radius = backdropBlur }
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

    /// The app whose audio is being transcribed, as the tap names its family,
    /// or nil while nothing is known to be playing. Set from the poll in
    /// PlayingApp.swift. The live box wears its icon, and every page that
    /// closes under it is tagged with it, so the ⌥ stack shows a Zoom box over
    /// a Chrome box when that is what happened.
    var playingApp: String? {
        didSet {
            guard playingApp != oldValue else { return }
            // The app's own line wears the app's own name until it goes.
            guard !holdsFinalCaption else { return }
            wearPlayingApp()
        }
    }

    private func wearPlayingApp() {
        view.icon = playingApp.map { AppCatalog.shared.icon(for: $0) }
        view.appName = playingApp.map { AppCatalog.shared.name(for: $0) }
        // The box makes room for the icon, so whatever is on screen re-fits.
        layout()
    }

    /// How loud what the app listens to is, for the glow along the box's
    /// bottom edge; nil paints none.
    var voiceMeter: VoiceMeter?
    /// Whether the glow is wanted at all: the menu's Audio Borealis row.
    var isBorealisEnabled = true
    private var borealis = AudioBorealis()
    private var borealisTickedAt: CFTimeInterval = 0
    /// The glow's knobs, live: the debug window turns them.
    var borealisConfig: AudioBorealis.Config {
        get { borealis.config }
        set { borealis.config = newValue }
    }

    /// The boxes' colors, the live box's and the stack's alike — see
    /// `Pill.Theme`. Set as the panels' appearance, which every color on
    /// them follows; nil, for auto, hands them back to the system's.
    var theme: Pill.Theme = .auto {
        didSet {
            guard theme != oldValue else { return }
            panel.appearance = theme.appearance
            history.theme = theme
        }
    }

    /// Where the icon goes, on the live box and the stack alike — see
    /// `Pill.IconStyle`.
    var iconStyle: Pill.IconStyle {
        get { view.iconStyle }
        set {
            guard newValue != view.iconStyle else { return }
            view.iconStyle = newValue
            layout()
        }
    }

    /// How the text sits in the boxes — see `Pill.TextAlignment`.
    var textAlignment: Pill.TextAlignment {
        get { view.textAlignment }
        set { view.textAlignment = newValue }
    }

    /// The untranslated transcript, kept even while the translated one is on
    /// screen, so ⌃ can show the original without waiting for new speech.
    private var sourceWords: [TimedWord] = []
    /// The translated rendering, when there is one: its words, the dimmed
    /// tail, the chunk boundaries paging carries across a break, and the
    /// transcript it was made from.
    private var translatedWords: TranslatedTranscript?
    /// Show the original beneath the translation. Only while a translation is
    /// what the box shows: in the source language there is nothing to pair it
    /// with. ⌃ does nothing while this is on — both languages are already on
    /// screen, and a key that hid one of them to show the other read as a
    /// glitch rather than a peek.
    var showsBothLanguages = false {
        didSet {
            guard showsBothLanguages != oldValue else { return }
            // Not left to the next poll: ⌃ held as the setting goes on would
            // show the original alone for a tick.
            if showsBothLanguages { showsSource = false }
            redraw()
        }
    }

    /// The pair points back out of the target language: the target itself is
    /// being spoken, and is translated into the other language. The target
    /// stays on top whichever way the pair points — it is the language being
    /// read, and a reader should not have to look for it — so here the
    /// transcript as spoken is the caption and the translation goes under it.
    /// Set by main.swift with the pair; see `translationPair()` there.
    var translationBelow = false {
        didSet {
            guard translationBelow != oldValue else { return }
            redraw()
        }
    }

    /// The stream carrying the target language while translating: the caption
    /// whenever a translation is shown at all.
    private var captionStream: CaptionStreams.Stream { translationBelow ? .source : .translated }

    /// The stream the box is drawing as its caption right now: the source as
    /// spoken when there is no translation to show or ⌃ asks for the original,
    /// else whichever carries the target language.
    private var primaryStream: CaptionStreams.Stream {
        showingSourceLanguage ? .source : captionStream
    }

    /// Set while a translation target is chosen. Without it a stale translation
    /// would keep being drawn after translation was switched off.
    var prefersTranslation = false {
        didSet {
            guard prefersTranslation != oldValue else { return }
            translatedWords = nil
            // Start the clock: the box stays empty rather than flashing the
            // original, but only for as long as a translation plausibly takes.
            lastTranslatedAt = Date()
            clearForLanguageChange()
        }
    }

    /// Empty the box when translation is switched on or off.
    ///
    /// Whatever is in it is in the language just left, and it would otherwise sit
    /// there until enough new words arrived to page it out: half a box in one
    /// language and half in the other. The next words open a clean box.
    ///
    /// The stacks are kept. Each already holds one language and ⌃ picks between
    /// them, so nothing there is mixed; the page on screen is banked into its own
    /// stack on the way out, in the language it was written in.
    private func clearForLanguageChange() {
        cancelHold()
        bankPages()
        boxIsCleared = true
        page = ""
        pendingCommit = ""
        tentative = ""
        lastShownText = ""
        startFreshOnNextText = false
        view.committed = ""
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }
        updateHistory()
    }
    /// ⌃ held: show the original language for as long as it is down. Never
    /// with both languages shown — see `showsBothLanguages`.
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
    /// The box holds a line of the app's own rather than the transcript's —
    /// see `showFinalCaption` — and nothing the recognizer or the translator
    /// still has in flight may replace it or fade it.
    private var holdsFinalCaption = false
    /// Draws that line in a word at a time, as speech would.
    private var finalCaptionTimer: Timer?

    /// How long `word` takes to say, as the recognizer would time it: a
    /// conversational four syllables a second, a beat between words, and a
    /// breath at a comma or a full stop. Syllables are the word's vowel
    /// groups, less an English silent e; a number is said as its digits'
    /// words would be, near enough at two syllables for each pair.
    private static func spokenDuration(of word: String) -> TimeInterval {
        let letters = word.lowercased().filter(\.isLetter)
        let syllables: Int
        if letters.isEmpty {
            syllables = max(1, word.filter(\.isNumber).count)
        } else {
            let vowels = Set("aeiouy")
            var groups = 0
            var inVowel = false
            for c in letters {
                let v = vowels.contains(c)
                if v, !inVowel { groups += 1 }
                inVowel = v
            }
            if letters.count > 2, letters.hasSuffix("e"), !letters.hasSuffix("le"), groups > 1 {
                groups -= 1
            }
            syllables = max(1, groups)
        }
        var seconds = 0.08 + Double(syllables) * 0.24
        if let last = word.last, ",;:".contains(last) { seconds += 0.35 }
        if let last = word.last, ".!?".contains(last) { seconds += 0.5 }
        // A brisker speaker than the figures above: 30% faster, three times.
        return seconds / (1.3 * 1.3 * 1.3)
    }

    // ── paging state ──
    // Broadcast subtitles never scroll a wall of text: they fill, clear, and
    // start again. `page` is what is on screen now; when the next words would
    // push past maxLines we drop the page entirely and begin a new one from
    // those words, rather than letting old text slide up out of view.
    private var page = ""
    private var pendingCommit = ""
    private var tentative = ""
    private var startFreshOnNextText = false
    /// An utterance ended and the translated pager's fresh mark is waiting for
    /// the words that are genuinely next — see `markPagersFreshAtUtteranceEnd`.
    private var translatedFreshDeferred = false

    // ── history ──
    // Pages that have scrolled off, oldest first, brought back by holding ⌥.
    // Recorded at every point a page closes rather than sampled, because by the
    // time a page is gone from `page` there is nothing left to read it from.
    private let history = HistoryController()
    /// Both renderings, paged together. Not two properties: handing one to a
    /// helper that reached for the other is what crashed on an overlapping access.
    private var streams = CaptionStreams()

    /// Whether the box is currently showing the language as spoken.
    ///
    /// `translatedWords == nil` is part of it and not an afterthought: a target
    /// can be chosen and still produce nothing to draw, which is exactly what
    /// happens when the audio turns out to be in the target language already. The
    /// box falls back to the original there, so the stack has to as well. Reading
    /// `prefersTranslation` alone left the stack pointed at an empty pager, and
    /// ⌥ showed nothing at all.
    private var showingSourceLanguage: Bool {
        guard !showsSource, prefersTranslation, translationProducesOutput else { return true }
        // Translation is on and working, but has not spoken yet. Falling back to
        // the original here is how switching translation on came to flash a line
        // of untranslated text before the first translation landed: the box was
        // cleared for the change and then immediately refilled in the language
        // just left. Nothing is the honest thing to show for the half second it
        // takes.
        //
        // Unless it has been much longer than that, in which case something has
        // gone wrong that the reader should not have to sit through blank. An
        // overlay showing nothing is indistinguishable from a broken app.
        return translatedWords == nil && waitedTooLongForTranslation
    }

    /// Whether translation is expected to produce anything at all: false while a
    /// language pack downloads, and false when the audio turns out to be in the
    /// target language already, where the untranslated captions are the answer.
    var translationProducesOutput = false {
        didSet { if translationProducesOutput != oldValue { lastTranslatedAt = Date() } }
    }

    /// When translated words last arrived, or when translation was last enabled.
    private var lastTranslatedAt = Date.distantPast
    /// Set by a fade: the first words after it restart the wait for their
    /// translation. The clock ran from the last translation before the fade
    /// and had long expired, so the original was drawn for the half second a
    /// translation takes — a flash of the other language at the start of every
    /// turn after a silence.
    private var patienceRestartsOnNextWords = false

    /// How long the box may stay empty waiting for a translation that is not
    /// coming before the original is shown instead.
    private let translationPatience: TimeInterval = 4

    private var waitedTooLongForTranslation: Bool {
        Date().timeIntervalSince(lastTranslatedAt) >= translationPatience
    }

    /// A box as the stack keeps it: what it showed as its caption and, when
    /// there was one, the other language that went with it — each in the
    /// language it was in on screen, whichever way the pair pointed then.
    /// The stack is its own record for that reason: read off one pager's
    /// boxes by the current direction, a turn in the other direction turned
    /// every earlier box into the other language.
    private struct StackBox {
        let text: String
        var under: String
        let app: String?
        /// Which way the pair pointed for this box: true when its caption was
        /// the speech itself and the translation went under. From the pager it
        /// came out of, not the direction at the time it was recorded — a box
        /// that closes at a turn's end is recorded once the next turn's words
        /// arrive, which may already be the other way round.
        let below: Bool
        /// The box's first word — its start in the audio and the word itself —
        /// by which an emission is known to be about these words at all, and
        /// its span, by which the other language is matched to it. Never by
        /// span alone: the recogniser's clock restarts, and a box from before
        /// the restart overlapped one after it in time and took its words.
        let start: TimeInterval
        let end: TimeInterval
        /// The pager box it was taken from: its stream and its place in that
        /// stream's count, by which a box revised after it closed is found
        /// again — see `reviseStack`.
        let stream: CaptionStreams.Stream
        let ordinal: Int
    }

    private var stack: [StackBox] = []
    /// How many of each pager's boxes have been taken into the stack.
    private var recorded: [CaptionStreams.Stream: Int] = [:]
    /// The last few emissions, newest first, kept for pairing: a box that
    /// closes at a turn's end is recorded once the next turn's first words
    /// arrive, when the emission about it has already been replaced.
    private var recentEmissions: [TranslatedTranscript] = []

    /// The stream whose closed boxes are the stack's: the caption's while a
    /// translation is being shown, the source otherwise — including while
    /// translation is on but has nothing to say, the audio being in the target
    /// language already, when the source is what the box shows.
    private var historyStream: CaptionStreams.Stream {
        prefersTranslation && translationProducesOutput ? captionStream : .source
    }

    /// Take into the stack the boxes that have left the screen since last
    /// time, from the caption's stream; the other stream's are the other
    /// language of those, and are only marked as seen. Each new box is paired
    /// straight away from the words on hand.
    private func recordClosedBoxes() {
        for stream in [CaptionStreams.Stream.source, .translated] {
            let total = streams.closedCount(stream)
            let unseen = total - (recorded[stream] ?? 0)
            recorded[stream] = total
            guard stream == historyStream, unseen > 0 else { continue }
            let boxes = streams.boxes(stream)
            let fresh = boxes.suffix(min(unseen, boxes.count))
            for (offset, box) in fresh.enumerated() {
                stack.append(StackBox(text: box.text, under: "", app: box.app,
                                      below: stream == .source, start: box.start, end: box.end,
                                      stream: stream, ordinal: total - fresh.count + offset))
                if Self.debugPaging {
                    FileHandle.standardError.write(
                        "[stack] + \(stream) \"\(box.text)\"\n".data(using: .utf8)!)
                }
            }
        }
        if stack.count > effectiveHistoryDepth {
            stack.removeFirst(stack.count - effectiveHistoryDepth)
        }
        pairHistory()
    }

    /// A change of speaker found late took words back out of boxes that had
    /// already closed, from `ordinal` on. The stack's copies of those go, and
    /// are taken again as they are now — the outgoing speaker's box without the
    /// new speaker's first words, and those words where they went.
    private func reviseStack(_ stream: CaptionStreams.Stream, from ordinal: Int) {
        stack.removeAll { $0.stream == stream && $0.ordinal >= ordinal }
        if let seen = recorded[stream], seen > ordinal { recorded[stream] = ordinal }
        if Self.debugPaging {
            FileHandle.standardError.write("[stack] revise \(stream) from #\(ordinal)\n"
                .data(using: .utf8)!)
        }
    }

    /// The other language under each box in the stack, from the words on
    /// hand. A box is paired from an emission only when that emission is about
    /// its words — its first word is one of the emission's own, at the same
    /// moment — so a translation that lands after its page has left the screen
    /// still reaches it, and an emission from another stretch of speech, on a
    /// clock that has since restarted, cannot. Same rule as the live box's for
    /// the text: the words over the box's span, and nothing when that is the
    /// caption again.
    private func pairHistory() {
        guard prefersTranslation else { return }
        let emissions = [translatedWords].compactMap { $0 } + recentEmissions
        guard !emissions.isEmpty else { return }
        for index in stack.indices {
            let box = stack[index]
            // The newest emission about this box's words, if any is.
            guard let transcript = emissions.first(where: { emission in
                let own = box.below ? emission.source : emission.words
                return own.contains { $0.start == box.start && box.text.hasPrefix($0.text) }
            }) else { continue }
            let other = box.below ? transcript.words : transcript.source
            let text = other.filter { $0.start >= box.start && $0.start < box.end }
                .map(\.text).joined(separator: " ")
            let under = TranslatedTranscript.sameWords(text, box.text) ? "" : text
            // Only ever towards something: a pairing can be bettered by a later
            // emission — the settled form of a tail — but never taken away by
            // one that has nothing over this span, or the caption's own words.
            guard !under.isEmpty, under != box.under else { continue }
            stack[index].under = under
            if Self.debugPaging {
                FileHandle.standardError.write(
                    "[stack] pair \"\(box.text.prefix(24))\" ← \"\(under.prefix(40))\"\n"
                        .data(using: .utf8)!)
            }
        }
    }

    /// Everything the stack holds goes, with the pagers' boxes.
    private func forgetStack() {
        stack.removeAll()
        recorded = [:]
        recentEmissions = []
    }

    /// The stack as shown, each box wearing the icon of the app it came from.
    /// Under ⌃ each box shows its other language, the way the live box shows
    /// the original; with both languages shown the other goes under, and ⌃
    /// is not held (`showsSource` is never set then).
    private var pastPages: [HistoryEntry] {
        stack.map { box in
            let swapped = showsSource && !box.under.isEmpty
            return HistoryEntry(text: swapped ? box.under : box.text,
                                icon: box.app.map { AppCatalog.shared.icon(for: $0) },
                                name: box.app.map { AppCatalog.shared.name(for: $0) },
                                under: showsBothLanguages ? box.under : "")
        }
    }

    /// How many closed pages ⌥ can reach back through. Adjustable in Settings;
    /// lowering it drops the oldest immediately rather than waiting for the
    /// buffer to be pushed down to the new size. Zero keeps none at all, which
    /// is how someone turns the whole thing off without losing the ⌥ gesture
    /// having ever meant anything. `unlimitedHistoryDepth` keeps every box,
    /// within `historyDepthCap`.
    ///
    /// Only the count. How long a silence forgets the stack is `historyExpiry`,
    /// and the two are deliberately not tied: someone who asks for every box
    /// has said nothing about how long they want them for.
    var historyDepth = OverlayController.defaultHistoryDepth {
        didSet {
            guard historyDepth != oldValue else { return }
            streams.trim(to: effectiveHistoryDepth)
            if stack.count > effectiveHistoryDepth {
                stack.removeFirst(stack.count - effectiveHistoryDepth)
            }
        }
    }

    /// The slider's last stop: keep everything. A sentinel rather than the cap
    /// itself, so a plist written at today's cap does not turn into a fixed
    /// number the day the cap moves.
    static let unlimitedHistoryDepth = Int.max

    /// Everything, out of the box. The expiry is what keeps the stack about
    /// what was just said; a count on top of it only ever lost a box someone
    /// was scrolling back for.
    static let defaultHistoryDepth = unlimitedHistoryDepth

    /// What "everything" comes to in practice. A page is a sentence or two, so
    /// this is a few hundred kilobytes of text at the very most — and a stack
    /// nobody could scroll to the end of long before then.
    static let historyDepthCap = 2000

    /// The depth the pagers are actually asked to keep.
    private var effectiveHistoryDepth: Int { min(historyDepth, Self.historyDepthCap) }

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

    /// Fired once the overlay has faded because no new text arrived.
    ///
    /// The engine uses it to drop a context that may be full of music, and the
    /// translator to drop everything it has not delivered: a box that has gone
    /// takes its pending work with it, or that work arrives into the next box as
    /// text from before the pause.
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

    /// The box's ceiling: a line of `Pill.maxLineCharacters` at the current
    /// text size, or less of the screen on one too narrow for it.
    private var maxWidth: CGFloat {
        let line = Pill.maxWidth(ofSize: view.fontSize, pad: SubtitleView.pad)
        guard let screen = NSScreen.main else { return min(line, 900) }
        return min(screen.frame.width * 0.75, line)
    }

    init(fontSize: CGFloat) {
        let initial = NSRect(x: 0, y: 0, width: 900, height: 80)
        panel = SubtitlePanel(contentRect: initial)
        view = SubtitleView(frame: initial)
        view.fontSize = fontSize
        // The blur beneath the view, both filling the panel, and the view telling
        // the blur its shape.
        let root = NSView(frame: initial)
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        view.backdrop = backdrop
        root.addSubview(backdrop)
        root.addSubview(view)
        panel.contentView = root
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
            // two are independent: peeking while dragging is fine. Inert with
            // both languages shown: there is nothing to peek at.
            let wantsSource = NSEvent.modifierFlags.contains(.control) && !self.showsBothLanguages
            if wantsSource != self.showsSource {
                self.showsSource = wantsSource
                self.redraw()
            }

            let wantsDrag = NSEvent.modifierFlags.contains(.shift) && !self.isSuppressed
            if wantsDrag != self.isDraggable {
                self.isDraggable = wantsDrag
                self.panel.ignoresMouseEvents = !wantsDrag && self.view.link == nil
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
            self?.tickAudioBorealis()
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
        // Same poll, same reason: an outside click unpins the search, and the
        // mouse buttons are as pollable as the modifiers.
        history.noticeClicks()
        // Never alongside ⇧: that is the drag gesture, and a second panel over
        // the box while it is being picked up just gets in the way. Pinned by
        // the search, the stack stays whatever the keys are doing: that is what
        // pinning is for.
        let held = flags.contains(.option) && !flags.contains(.shift)
        let wants = isHistoryEnabled && !isSuppressed && !pastPages.isEmpty
            && (held || history.isPinned)
        guard wants else {
            history.dismiss()
            return
        }

        // The stack follows the live box: peeking at the original with ⌃ and
        // leaving the boxes above it translated would be the worst of both.
        let entries = pastPages
        if history.shown != entries {
            let style = HistoryStyle(
                fontSize: SubtitleView.historyFontSize(for: view.fontSize),
                fill: view.backgroundOpacity * HistoryPillView.recession,
                textOpacity: historyTextOpacity,
                blur: backdropBlur,
                iconStyle: view.iconStyle,
                textAlignment: view.textAlignment)
            history.present(entries: entries, style: style, anchor: panel.frame,
                            centreX: boxCentreX, maxWidth: maxWidth,
                            animated: !isSwappingLanguage)
        } else {
            // The live box resizes on every word; the stack rides along with it.
            history.reposition(anchor: panel.frame, centreX: boxCentreX)
        }
    }

    /// One frame of the glow: read the meter, advance the driver, paint.
    /// Only while the box is up and the glow is wanted; otherwise the glow
    /// is dropped and the driver rests, so it opens from silence.
    private func tickAudioBorealis() {
        guard let voiceMeter, isBorealisEnabled, panel.alphaValue > 0, !boxIsCleared else {
            if view.borealis != nil {
                view.borealis = nil
                borealis.reset()
            }
            borealisTickedAt = 0
            return
        }
        let now = CACurrentMediaTime()
        let dt = borealisTickedAt == 0 ? 1.0 / 60 : min(0.05, now - borealisTickedAt)
        borealisTickedAt = now
        let reading = voiceMeter.read()
        let frame = borealis.step(dt: dt, loudness: reading.loudness, bands: reading.bands)
        // Nothing to paint in silence, and nothing to redraw for: the box is
        // left alone until a voice lifts the glow.
        view.borealis = frame.glow > 0.002 ? frame : nil
    }

    /// Point the reveal at the cursor, or turn it off.
    ///
    /// ⇧ is read here rather than reusing `isDraggable` so the box goes solid the
    /// moment the key is down: `isDraggable` only catches up on the next 0.15s
    /// modifier poll, which is long enough to start a drag through a hole.
    ///
    /// ⌥ suppresses it for a different reason: the pointer has to be over the
    /// stack to scroll it, and a hole punched through the live box under the
    /// cursor while the user is reading the history above it is pure noise. A
    /// stack pinned by its search is being read the same way, with ⌥ released.
    /// `frame` is the panel frame to measure against, for the case where the
    /// panel is about to be given one and has not got it yet.
    private func updateMask(for frame: NSRect? = nil) {
        let panelFrame = frame ?? panel.frame
        let flags = NSEvent.modifierFlags
        guard isRevealEnabled,
              !holdsFinalCaption,
              panel.alphaValue > 0,
              !flags.contains(.shift),
              !flags.contains(.option),
              !history.isPinned else {
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
        guard !holdsFinalCaption else { return }
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

        boxIsCleared = false
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
        if patienceRestartsOnNextWords {
            patienceRestartsOnNextWords = false
            lastTranslatedAt = Date()
        }
        let visible = page(.source, words, chunkStarts: [])
        // Drawn when the source is the caption: with no translation to show,
        // under ⌃, or with the target language itself being spoken, where the
        // translation goes under it. Not for the original under a translation:
        // that comes from the transcript the translation was made of, with the
        // translation, never from words it has not seen — see `underCaption`.
        guard primaryStream == .source else { return }
        showWords(visible, under: underCaption)
    }

    /// The transcript translated. Stored and drawn unless ⌃ is asking for the
    /// original.
    func setTranslatedWords(_ transcript: TranslatedTranscript) {
        if let previous = translatedWords {
            recentEmissions.insert(previous, at: 0)
            if recentEmissions.count > 4 { recentEmissions.removeLast() }
        }
        translatedWords = transcript
        lastTranslatedAt = Date()
        // Translated words are proof that translation produces output, whatever
        // the last word update was told: after a pair change the pack is
        // confirmed again, and a turn that ends inside that moment sends no
        // further words to carry the news. Without this its translation arrived
        // at a box that believed there was none, and went under nothing.
        translationProducesOutput = true
        // The utterance's last translation lands after the endpoint that closed
        // it: the settled form of the page on screen, not new speech, and it
        // pages into that page. The fresh mark the endpoint left for this
        // stream is applied by the first words that are new.
        if translatedFreshDeferred, !transcript.settlesUtterance {
            translatedFreshDeferred = false
            streams.markFresh(.translated)
        }
        pageTranslated(transcript)
    }

    /// Page the translation and draw it, or the caption it goes under.
    private func pageTranslated(_ transcript: TranslatedTranscript) {
        let visible = page(.translated, transcript.words, chunkStarts: transcript.chunkStarts,
                           speculativeFrom: transcript.speculativeFrom)
        pairHistory()
        guard !showsSource else { return }
        if translationBelow {
            // The caption is the transcript as spoken, already on screen; the
            // translation goes under it. Not for a box that has faded — the
            // page it would bring back is finished with, and new speech returns
            // through the source words as it always has.
            guard !boxIsCleared else { return }
            showWords(streams.currentWords(.source), under: underCaption)
        } else {
            showWords(visible, speculativeFrom: transcript.speculativeFrom, under: underCaption)
        }
    }

    /// Whether the other language goes under the caption right now: the
    /// setting, and a translation that is expected. Not a question of ⌃, which
    /// changes what is drawn and nothing else — the streams are paged the same
    /// way whether or not they are on screen, or the stack would not match the
    /// box.
    private var pairsLanguages: Bool {
        showsBothLanguages && prefersTranslation && translationProducesOutput
    }

    /// The other language, for under the caption: the words the translation was
    /// made from, over the translated page's span — or, with the target
    /// language itself being spoken, the translation over the caption's span
    /// instead (`translationBelow`). Translated words
    /// are timed over the sentence they render, so a translated page begins
    /// where a source sentence does, and the pager has already made sure that
    /// much fits — see `longestFittingPrefix`. Only ever those words: what the
    /// recogniser has said since is not translated yet, and at an utterance's
    /// end it is the next speaker, possibly in the other language — the old
    /// translation over the new speech showed French under French. Empty
    /// whenever the box is not showing a translation.
    ///
    /// And never the same language twice. A translation that came back as its
    /// own original — the pair pointing the wrong way for the first word or two
    /// of a new speaker, before the recogniser named the language — is the
    /// original, and is shown once.
    /// The paragraph under the caption: settled text, and the unsettled tail to
    /// draw dimmed after it.
    typealias Under = (settled: String, tentative: String)

    private var underCaption: Under {
        guard pairsLanguages, !showingSourceLanguage, let transcript = translatedWords else { return ("", "") }
        let caption = streams.currentWords(captionStream)
        guard let last = caption.last else { return ("", "") }
        let from = streams.start(captionStream)
        let other = translationBelow ? transcript.words : transcript.source
        let span = other.filter { $0.start >= from && $0.start < last.end }
        // Under the caption the translation keeps its unsettled tail dimmed, as
        // it is when it is the caption: the same words, split at the same
        // moment, so the translation timing setting reads the same either way.
        // The original as spoken has no tail.
        let cut = translationBelow ? transcript.speculativeFrom : .greatestFiniteMagnitude
        let settled = span.filter { $0.start < cut }.map(\.text).joined(separator: " ")
        var tentative = span.filter { $0.start >= cut }.map(\.text).joined(separator: " ")
        // `Pill.attributed` joins the two runs with no separator.
        if !settled.isEmpty, !tentative.isEmpty { tentative = " " + tentative }
        let whole = settled + tentative
        return TranslatedTranscript.sameWords(whole, caption.map(\.text).joined(separator: " "))
            ? ("", "") : (settled, tentative)
    }

    /// Run a stream through its own pager, measuring with the live box's geometry
    /// so the hidden stack breaks where it would have if it were on screen.
    /// `tentative` must be whatever the box would be drawing alongside these
    /// words, because it is measured alongside them.
    ///
    /// The dimmed tail occupies the box, so a page overflows sooner with one than
    /// without. Paging the stack without it meant the pager thought a page still
    /// had room after the box had already moved on, and a closed box only reached
    /// the stack once enough settled words arrived to overflow it unaided: the
    /// history ran a settle or more behind the screen.
    /// Advance one stream and hand back the page to draw.
    ///
    /// `tentative` must be whatever the box would be drawing alongside these
    /// words, because it is measured alongside them: the dimmed tail occupies the
    /// box, so a page overflows sooner with one than without.
    /// Advance one stream and hand back the page to draw.
    ///
    /// A pending fresh page is applied to both streams first, so a pause breaks
    /// them at the same word. `CaptionStreams` owns both, which is why that is
    /// safe to do here: the earlier shape passed one pager `inout` and reached for
    /// the other inside the call, an overlapping access that Swift traps on at
    /// runtime. It crashed on the first translated word after a pause, and neither
    /// the compiler nor the test suite could see it.
    private func page(_ stream: CaptionStreams.Stream, _ words: [TimedWord],
                      chunkStarts: [TimeInterval],
                      speculativeFrom: TimeInterval = .greatestFiniteMagnitude) -> [TimedWord] {
        if startFreshOnNextText {
            startFreshOnNextText = false
            streams.markFresh(.source)
            if !translatedFreshDeferred { streams.markFresh(.translated) }
        }
        // Whichever stream is the caption pages on both paragraphs, with the
        // other language's words over the same span — see `longestFittingPrefix`.
        let paired: [TimedWord]? = pairsLanguages && stream == captionStream
            ? (translationBelow ? translatedWords?.words : translatedWords?.source) : nil
        let onScreen = stream == primaryStream
        // What the reader has to get through before the page may turn: the
        // caption as it stands and, with both languages shown, the paragraph
        // drawn under it — `view.secondary`, at its smaller size. The page
        // turns on whichever of the two fills first, and the hold is sized on
        // whichever takes longer to read.
        let captionBefore = streams.currentWords(stream).map(\.text).joined(separator: " ")
        let underBefore = onScreen ? view.secondary + view.secondaryTentative : ""
        let paged = streams.ingest(stream, words: words, chunkStarts: chunkStarts,
                                   depth: effectiveHistoryDepth, allowCarry: allowsCarry,
                                   speculativeFrom: speculativeFrom, app: playingApp) { candidates in
            longestFittingPrefix(candidates, pairedWith: paired)
        }
        if let revised = paged.revisedFrom { reviseStack(stream, from: revised) }
        if paged.brokePage {
            pageShownAt = Date()
            if onScreen {
                pendingPageChange = true
                holdPage(caption: captionBefore, under: underBefore)
            }
        }
        if paged.brokePage || paged.revisedFrom != nil { recordClosedBoxes() }
        pageStartTime = streams.start(stream)
        return paged.visible
    }

    /// The page on screen is leaving. Keep it for as long as a reader who has
    /// been reading since it appeared still needs to finish it — its text as
    /// drawn, the slower-read of its two paragraphs when there are two, at
    /// `readingRate`, less the time it has had — and no longer than `maxHold`.
    /// A slow speaker's page was read as it filled and turns at once; a fast
    /// one's, or a translated sentence that landed whole, gets its moment. The
    /// words keep arriving into the pager meanwhile, and the redraw at the end
    /// shows wherever they have got to. A hold already running is left alone:
    /// a page that turned during it was never seen, and is owed nothing.
    private func holdPage(caption: String, under: String) {
        if let holdUntil, holdUntil > Date() { return }
        let shown = Date().timeIntervalSince(displayedPageSince)
        let needed = max(readingTime(caption, scale: 1),
                         readingTime(under, scale: SubtitleView.secondaryScale))
        let owed = needed - shown
        let hold = min(max(owed, 0), maxHold)
        if Self.debugPaging {
            FileHandle.standardError.write(String(
                format: "[page] turn: %d + %d chars need %.1fs, shown %.1fs → hold %.2fs\n",
                caption.count, under.count, needed, shown, hold).data(using: .utf8)!)
        }
        guard hold > 0.05 else { holdUntil = nil; return }
        holdUntil = Date().addingTimeInterval(hold)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.holdUntil = nil
            self.redraw()
        }
    }

    /// Seconds to read `text` drawn at `scale` of the caption's size.
    private func readingTime(_ text: String, scale: CGFloat) -> TimeInterval {
        Double(text.count) / (readingRate * Double(scale))
    }

    /// The box is being emptied: nothing left to hold for.
    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdUntil = nil
        pendingPageChange = false
    }

    /// Draw whichever rendering is currently wanted, from what the pagers hold.
    ///
    /// Nothing is re-paged. Both streams have already been broken into boxes by
    /// their own pager as words arrived, so a swap is a matter of drawing the
    /// other one's current page: idempotent by construction, and incapable of
    /// disagreeing with the stack it is shown above.
    private func redraw() {
        defer {
            isSwappingLanguage = true
            updateHistory()
            isSwappingLanguage = false
        }
        // The stack still swaps with ⌃ while the box is down; the box itself does
        // not come back until there is something new to say.
        guard !boxIsCleared else { return }
        if primaryStream == .source {
            showWords(streams.currentWords(.source), under: underCaption)
        } else if let translated = translatedWords {
            showWords(streams.currentWords(.translated),
                      speculativeFrom: translated.speculativeFrom, under: underCaption)
        }
    }

    /// `chunkStarts` are the audio times settled units begin at, when the caller
    /// has such units. Live translation does: it settles a clause at a time. Given
    /// them, a page that overflows restarts at the last chunk boundary it showed
    /// rather than at the word that spilled, so the final clause of the old box
    /// opens the new one and stays readable across the break. Empty for
    /// transcription, which pages as it always has.
    /// `speculativeFrom` is the audio time the unsettled tail begins at, so the
    /// words from there on are drawn dimmed. It is part of `words` rather than a
    /// string beside them, which is what lets the box fill with it and turn over
    /// when full rather than evicting settled clauses to make room.
    /// `secondary` is the original to set under these words, when both
    /// languages are shown — see `secondaryText`; empty draws the words alone.
    func showWords(_ words: [TimedWord],
                   speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                   under: Under = ("", "")) {
        guard !isSuppressed, !holdsFinalCaption else { return }
        // A page held for reading — see `holdPage(after:)`. Its own redraw
        // comes back here when it ends.
        if let holdUntil, holdUntil > Date() { return }
        guard !words.isEmpty else { return }

        // `words` is already the page: whichever pager owns this stream broke it,
        // and the same break put the box that left into the stack. Deciding it
        // again here is what let the two drift apart.
        let settled = words.filter { $0.start < speculativeFrom }
        let unsettled = words.filter { $0.start >= speculativeFrom }
        let text = settled.map(\.text).joined(separator: " ")
        // `Pill.attributed` concatenates the two runs with no separator, so the
        // dimmed one carries the space that divides them.
        var speculative = unsettled.map(\.text).joined(separator: " ")
        if !text.isEmpty, !speculative.isEmpty { speculative = " " + speculative }

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
        // the live translation frozen on its first guess. The original under
        // the caption counts the same way: it changes with every spoken word
        // while the translation above it waits for the clause to settle.
        guard text != lastShownText || speculative != tentative
                || under.settled != view.secondary || under.tentative != view.secondaryTentative
        else { return }
        lastShownText = text
        lastTextAt = Date()
        // A new page: the first draw is when its reading time starts. A box
        // coming back from empty is a new page too.
        if pendingPageChange || boxIsCleared {
            displayedPageSince = Date()
            pendingPageChange = false
        }

        page = text
        pendingCommit = ""
        tentative = speculative
        boxIsCleared = false
        view.committed = page
        view.tentative = speculative
        view.secondary = under.settled
        view.secondaryTentative = under.tentative
        layout()
        show()
    }

    /// Index one past the last word that still fits within `maxLines` — and,
    /// when the original goes under these words, one past the last whose
    /// original still fits its own lines too, so the page turns when either
    /// paragraph fills. The original of a run of translated words is the
    /// speech over the same span. Translated words are spread over the
    /// sentence they render, so within a sentence the span is approximate; at
    /// a sentence's edges it is exact, and with chunk boundaries to carry from
    /// that is where a page restarts anyway.
    private func longestFittingPrefix(_ words: [TimedWord],
                                      pairedWith original: [TimedWord]?) -> Int {
        var end = 0
        while end < words.count {
            let candidate = words[0...end].map(\.text).joined(separator: " ")
            if view.lineCount(committed: candidate, tentative: "", width: maxWidth) > view.maxLines {
                return end
            }
            if let original {
                let span = original.lazy
                    .filter { $0.start >= words[0].start && $0.start < words[end].end }
                    .map(\.text).joined(separator: " ")
                if !span.isEmpty, view.secondaryLineCount(span, width: maxWidth) > view.maxLines {
                    return end
                }
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
        markPagersFreshAtUtteranceEnd()
    }

    /// Someone else started speaking at `time`, in audio time. Their words
    /// start a box of their own, from the first of them: the diarizer names a
    /// change a second or two late, when those words are already drawn at the
    /// end of the outgoing speaker's box, or have closed with it into the
    /// stack, and they are taken back from there.
    ///
    /// The spoken words are paged again at once, having everything the break
    /// needs; the translation breaks as its words before the change settle.
    func markSpeakerChange(at time: TimeInterval) {
        if Self.debugPaging {
            let near = sourceWords.filter { abs($0.start - time) < 2 }
                .map { String(format: "%@@%.2f", $0.text, $0.start) }.joined(separator: " ")
            FileHandle.standardError.write(String(
                format: "[page] speaker change at %.2fs, page from %.2fs: %@\n",
                time, streams.start(.source), near).data(using: .utf8)!)
        }
        streams.markSpeakerChange(at: time)
        guard !holdsFinalCaption else { return }
        if !sourceWords.isEmpty {
            let visible = page(.source, sourceWords, chunkStarts: [])
            if primaryStream == .source, !boxIsCleared { showWords(visible, under: underCaption) }
            if Self.debugPaging {
                FileHandle.standardError.write(String(
                    format: "[page] after change: page from %.2fs \"%@\", last box \"%@\"\n",
                    streams.start(.source), visible.map(\.text).joined(separator: " "),
                    streams.boxes(.source).last?.text ?? "").data(using: .utf8)!)
            }
        }
        if let translatedWords, !boxIsCleared {
            pageTranslated(translatedWords)
        }
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
        markPagersFreshAtUtteranceEnd()
    }

    /// A page just left the screen. Keep it for ⌥.
    ///
    /// Deduplicated against the last entry: a page can close by more than one
    /// route in the same beat — an overflow immediately after a pause, say — and
    /// two identical boxes in the stack read as a stutter, not as history.
    /// The page on screen goes to the stack now, in both languages, and the
    /// next words start a page of their own. For a fade and for a clear: ⌥ is
    /// asked for the box exactly then, and a mark for the next words left it
    /// out of the stack until someone spoke again.
    private func bankPages() {
        streams.close(depth: effectiveHistoryDepth)
        translatedFreshDeferred = false
        recordClosedBoxes()
    }

    /// The next words begin a page of their own, in both languages.
    private func markPagersFresh() {
        streams.markFresh()
        translatedFreshDeferred = false
    }

    /// The next words begin a page of their own — in the source now, and in
    /// the translation once its last words for this utterance have landed.
    /// Translation runs behind speech: the settled form of the dimmed tail
    /// arrives after the endpoint, and a translated pager marked fresh here
    /// put its anchor past every one of those words, so they were dropped and
    /// the tail stayed dimmed for good. The mark is applied by the first
    /// translated words that are new — see `setTranslatedWords`. With no
    /// translation there is nothing to wait for.
    private func markPagersFreshAtUtteranceEnd() {
        streams.markFresh(.source)
        if prefersTranslation {
            translatedFreshDeferred = true
        } else {
            streams.markFresh(.translated)
        }
    }

    private func trimLeadingSpace(_ s: String) -> String {
        var out = s
        while out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    // MARK: layout / visibility

    /// Where the box is anchored horizontally, which is steadier than where it
    /// currently is. `layout` resolves the same value; the stack hangs off this so
    /// it does not inherit the box's per-word rounding.
    private var boxCentreX: CGFloat {
        anchor?.x ?? NSScreen.main?.frame.midX ?? panel.frame.midX
    }

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
        // Both stacks, not the one on screen: with a target chosen the visible one
        // can be empty while the other still holds a session's worth of boxes, and
        // guarding on the visible one alone left that never expiring.
        guard isHistoryExpiryEnabled, !streams.isEmpty || !stack.isEmpty else { return }
        // Not while it is on screen. Someone holding ⌥ is reading it, and a
        // stack that empties under their eyes because nobody spoke for a minute
        // is the one moment this must not fire.
        guard history.shown.isEmpty else { return }
        guard Date().timeIntervalSince(lastTextAt) >= historyExpiry else { return }
        streams.clear()
        forgetStack()
    }

    private func fadeIfTextIdle() {
        guard !isDraggable, !holdsFinalCaption, panel.alphaValue > 0 else { return }
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
            self.bankPages()
            self.boxIsCleared = true
            // The stored transcripts go too. They outlive the box on purpose so ⌃
            // can swap language instantly, but everything in them predates the
            // fade, so keeping them is keeping exactly what must never be shown
            // again.
            self.sourceWords = []
            self.translatedWords = nil
            self.recentEmissions = []
            self.patienceRestartsOnNextWords = true
            self.page = ""
            self.pendingCommit = ""
            self.tentative = ""
            self.view.committed = ""
            self.view.tentative = ""
            self.view.secondary = ""
            self.view.secondaryTentative = ""

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
                view.secondary = ""
                view.secondaryTentative = ""
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
            view.secondary = ""
            view.secondaryTentative = ""
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

    /// Put `text` in the box as the last caption of a run: the trial's free
    /// minutes ending. Drawn like any caption, a word at a time, glow and all,
    /// and held there against the transcript and the idle fade until
    /// `setPaused` or `clearAndHide` takes it down.
    func showFinalCaption(_ text: String, link: (text: String, open: () -> Void)? = nil) {
        guard !isSuppressed else { return }
        history.dismiss()
        cancelHold()
        holdsFinalCaption = true
        // Said by Subtitles, not by the app playing: the box wears this app's
        // name and icon for it.
        view.icon = NSApp.applicationIconImage
        view.appName = "Subtitles"
        pendingCommit = ""
        tentative = ""
        startFreshOnNextText = true
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        view.link = link
        // Clicks reach the box while the link is up, and only then.
        panel.ignoresMouseEvents = link == nil
        // A line break in `text` stays one: the word after it opens a line.
        var words: [String] = []
        var opensLine: Set<Int> = []
        for (i, part) in text.split(separator: "\n").enumerated() {
            if i > 0 { opensLine.insert(words.count) }
            words += part.split(separator: " ").map(String.init)
        }
        var shown = 0
        var pageStart = 0
        func joined() -> String {
            var out = ""
            for i in pageStart..<shown {
                if i > pageStart { out += opensLine.contains(i) ? "\n" : " " }
                out += words[i]
            }
            return out
        }
        func step() {
            shown += 1
            var line = joined()
            // Pages like a caption: a word that would overflow the box opens
            // the next one.
            if shown - 1 > pageStart,
               view.lineCount(committed: line, tentative: "", width: maxWidth) > view.maxLines {
                pageStart = shown - 1
                line = joined()
            }
            boxIsCleared = false
            lastShownText = line
            lastTextAt = Date()
            page = line
            view.committed = line
            layout()
            show()
            finalCaptionTimer?.invalidate()
            finalCaptionTimer = nil
            guard shown < words.count else { return }
            // The next word lands once this one has been said.
            finalCaptionTimer = Timer.scheduledTimer(
                withTimeInterval: Self.spokenDuration(of: words[shown - 1]),
                repeats: false) { [weak self] _ in
                    guard let self, self.holdsFinalCaption else { return }
                    step()
                }
        }
        step()
    }

    /// Wipe the box and fade it out, leaving it free to come back on the next
    /// word. Used when the engine underneath changes — model or source switch.
    func clearAndHide() {
        if view.link != nil {
            view.link = nil
            if !isDraggable { panel.ignoresMouseEvents = true }
        }
        // The app's name comes back once the box is out of sight, not while
        // the line Subtitles said is still fading under it.
        let rewear = holdsFinalCaption
        holdsFinalCaption = false
        finalCaptionTimer?.invalidate()
        finalCaptionTimer = nil
        // The history goes with it. It survives the idle fade on purpose, but a
        // pause or a model switch is the user saying this transcript is over, and
        // ⌥ offering the last thing a since-replaced model heard is a puzzle.
        streams.clear()
        forgetStack()
        translatedFreshDeferred = false
        history.dismiss()
        cancelHold()
        boxIsCleared = true
        lastShownText = ""
        lastTextAt = .distantPast
        page = ""
        pendingCommit = ""
        tentative = ""
        pageStartTime = 0
        startFreshOnNextText = false
        view.committed = ""
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, rewear, !self.holdsFinalCaption else { return }
            self.wearPlayingApp()
        })
    }
}
