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
    var blur = Pill.backdropBlur
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
    case lines, background, blur, reveal, keep, dimness, expiry
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
    /// Three stops, top to bottom, and where the middle one sits.
    let wallpaper: [NSColor]
    let wallpaperMid: CGFloat
    /// The wallpaper's soft ellipses, `--desktop-bg`'s radial gradients in the
    /// order the stylesheet lists them: position and radii as fractions of the
    /// screen, in CSS's y-down, and the fraction of the radius the colour runs
    /// out at.
    struct Glow {
        let at: NSPoint
        let radii: NSSize
        let color: NSColor
        let stop: CGFloat
    }
    let glows: [Glow]
    /// `--bar-bg`: the menu bar, without the blur it has on the site.
    let bar: NSColor
    let window: NSColor
    /// Ink alphas: the title bar's gradient, and the hairline it ends on.
    let barTop: CGFloat
    let barBottom: CGFloat
    let line: CGFloat
    /// `--meeting-bg`, `--tile-bg` (two stops) and `--recess`.
    let meeting: NSColor
    let tile: [NSColor]
    let recess: NSColor
    /// `--window-ring` and `--window-inner`: the translucent line outside a
    /// window's edge, and the faint light one inside it that dark mode adds.
    let ring: NSColor
    let inner: NSColor
    /// `--border-strong`, around the screen.
    let edge: NSColor
    /// Shadows are the one thing that does not survive a palette swap: the dark
    /// one is deep because it falls on a near-black desktop, where nothing less
    /// reads at all, and the same shadow on a light one is a smear.
    let shadow: CGFloat

    static let light = DesktopPalette(
        ink: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.110, alpha: 1),   // 22 23 28
        wallpaper: [
            NSColor(srgbRed: 0.780, green: 0.761, blue: 1, alpha: 1),        // #c7c2ff
            NSColor(srgbRed: 0.918, green: 0.839, blue: 0.957, alpha: 1),    // #ead6f4
            NSColor(srgbRed: 1, green: 0.847, blue: 0.761, alpha: 1),        // #ffd8c2
        ],
        wallpaperMid: 0.48,
        glows: [
            Glow(at: NSPoint(x: 0.16, y: 0.10), radii: NSSize(width: 0.55, height: 0.60),
                 color: NSColor(srgbRed: 0.439, green: 0.392, blue: 1, alpha: 0.62), stop: 0.64),
            Glow(at: NSPoint(x: 0.86, y: 0.18), radii: NSSize(width: 0.48, height: 0.55),
                 color: NSColor(srgbRed: 1, green: 0.431, blue: 0.667, alpha: 0.50), stop: 0.66),
            Glow(at: NSPoint(x: 0.72, y: 0.96), radii: NSSize(width: 0.58, height: 0.50),
                 color: NSColor(srgbRed: 1, green: 0.659, blue: 0.392, alpha: 0.66), stop: 0.66),
            Glow(at: NSPoint(x: 0.12, y: 0.90), radii: NSSize(width: 0.42, height: 0.46),
                 color: NSColor(srgbRed: 0.314, green: 0.769, blue: 0.922, alpha: 0.50), stop: 0.66),
        ],
        bar: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.980, alpha: 0.35),
        window: NSColor(srgbRed: 0.992, green: 0.992, blue: 1, alpha: 1),    // #fdfdff
        barTop: 0.06, barBottom: 0.13, line: 0.13,
        meeting: NSColor(srgbRed: 0.945, green: 0.949, blue: 0.965, alpha: 1), // #f1f2f6
        tile: [
            NSColor(srgbRed: 0.992, green: 0.992, blue: 1, alpha: 1),        // #fdfdff
            NSColor(srgbRed: 0.914, green: 0.922, blue: 0.949, alpha: 1),    // #e9ebf2
        ],
        recess: NSColor(white: 0, alpha: 0.045),
        ring: NSColor(white: 0, alpha: 0.08),
        inner: .clear,
        edge: NSColor(srgbRed: 0.071, green: 0.071, blue: 0.094, alpha: 0.16),
        shadow: 0.28)

    static let dark = DesktopPalette(
        ink: .white,
        wallpaper: [
            NSColor(srgbRed: 0.090, green: 0.078, blue: 0.184, alpha: 1),    // #17142f
            NSColor(srgbRed: 0.169, green: 0.106, blue: 0.251, alpha: 1),    // #2b1b40
            NSColor(srgbRed: 0.227, green: 0.118, blue: 0.169, alpha: 1),    // #3a1e2b
        ],
        wallpaperMid: 0.50,
        glows: [
            Glow(at: NSPoint(x: 0.16, y: 0.10), radii: NSSize(width: 0.55, height: 0.60),
                 color: NSColor(srgbRed: 0.408, green: 0.345, blue: 1, alpha: 0.50), stop: 0.64),
            Glow(at: NSPoint(x: 0.86, y: 0.18), radii: NSSize(width: 0.48, height: 0.55),
                 color: NSColor(srgbRed: 0.882, green: 0.275, blue: 0.588, alpha: 0.36), stop: 0.66),
            Glow(at: NSPoint(x: 0.72, y: 0.96), radii: NSSize(width: 0.58, height: 0.50),
                 color: NSColor(srgbRed: 1, green: 0.541, blue: 0.298, alpha: 0.36), stop: 0.66),
            Glow(at: NSPoint(x: 0.12, y: 0.90), radii: NSSize(width: 0.42, height: 0.46),
                 color: NSColor(srgbRed: 0.157, green: 0.627, blue: 0.882, alpha: 0.32), stop: 0.66),
        ],
        bar: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.114, alpha: 0.55),
        window: NSColor(srgbRed: 0.063, green: 0.067, blue: 0.086, alpha: 1), // #101116
        barTop: 0.09, barBottom: 0.045, line: 0.045,
        meeting: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.114, alpha: 1), // #16171d
        tile: [
            NSColor(srgbRed: 0.149, green: 0.157, blue: 0.220, alpha: 1),    // #262838
            NSColor(srgbRed: 0.098, green: 0.102, blue: 0.141, alpha: 1),    // #191a24
        ],
        recess: NSColor(white: 0, alpha: 0.30),
        ring: NSColor(white: 0, alpha: 0.60),
        inner: NSColor(white: 1, alpha: 0.10),
        edge: NSColor(white: 1, alpha: 0.18),
        shadow: 0.60)

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

    // ── the call ──

    /// Who is talking, handed round the tiles the way it goes in a real call:
    /// never straight back to the same person, and held for an uneven beat,
    /// because a fixed rotation reads as a carousel rather than a conversation.
    /// The beats are the site demo's.
    private static let people: [(initials: String, name: String, face: [NSColor])] = [
        ("AO", "Amara", [NSColor(srgbRed: 0.435, green: 0.416, blue: 0.902, alpha: 1),
                         NSColor(srgbRed: 0.310, green: 0.294, blue: 0.753, alpha: 1)]),
        ("YT", "Yuki",  [NSColor(srgbRed: 0.851, green: 0.478, blue: 0.306, alpha: 1),
                         NSColor(srgbRed: 0.694, green: 0.333, blue: 0.184, alpha: 1)]),
        ("TR", "Tomás", [NSColor(srgbRed: 0.298, green: 0.616, blue: 0.549, alpha: 1),
                         NSColor(srgbRed: 0.200, green: 0.459, blue: 0.416, alpha: 1)]),
        ("LK", "Lena",  [NSColor(srgbRed: 0.541, green: 0.435, blue: 0.722, alpha: 1),
                         NSColor(srgbRed: 0.373, green: 0.290, blue: 0.541, alpha: 1)]),
    ]
    private var speaking = 0
    /// How far each tile's ring has faded in, 0…1. The demo transitions the
    /// border over a quarter second, so handing the ring on is a fade, not a
    /// jump.
    private var rings: [CGFloat] = [1, 0, 0, 0]
    private var nextHand: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var frames: Timer?
    private static let fps: TimeInterval = 1 / 30

    /// Still rings and no hand-off under Reduce Motion, as the demo does: it is
    /// who is speaking, not an animation.
    private var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The pulses run while the stage is in a window and stop with it, for the
    /// same reason the preview's own loop does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frames?.invalidate()
        frames = nil
        guard window != nil else { return }
        let now = CACurrentMediaTime()
        lastFrame = now
        nextHand = now + 1.9
        let timer = Timer(timeInterval: Self.fps, repeats: true) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        frames = timer
    }

    deinit { frames?.invalidate() }

    private func advance() {
        let now = CACurrentMediaTime()
        let dt = now - lastFrame
        lastFrame = now
        if !calm, now >= nextHand {
            speaking = (speaking + 1 + Int.random(in: 0..<(Self.people.count - 1))) % Self.people.count
            nextHand = now + 2.1 + Double.random(in: 0..<1.7)
        }
        for i in rings.indices {
            let target: CGFloat = i == speaking ? 1 : 0
            let step = CGFloat(dt / 0.25)
            rings[i] = target > rings[i] ? min(target, rings[i] + step) : max(target, rings[i] - step)
        }
        needsDisplay = true
    }

    // ── drawing ──

    /// One hundredth of the screen's width, near enough: the demo draws every
    /// piece of its chrome in multiples of this, so the same multiples here are
    /// what keep the model to scale. 0.91 rather than 1 for the reason the
    /// stylesheet gives — that slope reaches the demo's cap at the width the
    /// demo tops out at.
    private var u: CGFloat { bounds.width * 0.0091 }
    /// Where the desktop starts: the stack rises to the menu bar's edge and no
    /// further, because on a Mac a window does not go over the menu bar and
    /// neither does the stack.
    var menuBarHeight: CGFloat { 2.95 * u }
    /// One screen pixel in overlay points: hairlines are drawn in these, since a
    /// half-point line scaled to a third of itself is not a line.
    private var px: CGFloat { 1 / max(contentScale, 0.01) }

    /// A desktop for the subtitles to sit on, with a menu bar over it and a
    /// window in the middle of it for the pointer reveal to reveal. A hole
    /// punched onto the settings window's own background would show nothing
    /// being uncovered, which is the one thing that control is about.
    ///
    /// All of it is the site demo's: the same wallpaper, the same bar and the
    /// same call, in whichever of its two palettes matches the appearance this
    /// window is being drawn in. Everything here is in overlay points, which are
    /// the simulated screen's own points, and the stage's scale takes them down
    /// with everything else.
    override func draw(_ dirtyRect: NSRect) {
        let palette = DesktopPalette.matching(effectiveAppearance)
        let now = CACurrentMediaTime()
        drawDesktop(palette)
        let bar = drawMenuBar(palette, now: now)
        drawCall(palette, below: bar, now: now)
    }

    /// Repaint on a change of appearance. The colours are picked in `draw`, so
    /// there is nothing to update — only a reason to draw again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glyphs.removeAll()
        needsDisplay = true
    }

    private func drawDesktop(_ palette: DesktopPalette) {
        NSGradient(colors: palette.wallpaper, atLocations: [0, palette.wallpaperMid, 1],
                   colorSpace: .sRGB)?
            // CSS measures its 160° clockwise from up; NSGradient measures
            // counter-clockwise from the x axis, which is 90 less than it.
            .draw(in: bounds, angle: -70)
        for glow in palette.glows { draw(glow) }
    }

    /// One of the wallpaper's soft ellipses. Position and radii are fractions of
    /// the stage, the way the stylesheet states them, with the y turned over
    /// because the stylesheet counts from the top.
    private func draw(_ glow: DesktopPalette.Glow) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rx = bounds.width * glow.radii.width
        let ry = bounds.height * glow.radii.height
        guard rx > 0, ry > 0 else { return }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glow.color.cgColor, glow.color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, glow.stop]) else { return }

        ctx.saveGState()
        // Circular gradients only, so the ellipse comes from squashing the space
        // it is drawn in — the same trick the reveal's mask uses.
        ctx.translateBy(x: bounds.width * glow.at.x, y: bounds.height * (1 - glow.at.y))
        ctx.scaleBy(x: 1, y: ry / rx)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: rx, options: [])
        ctx.restoreGState()
    }

    /// The bar across the top: the mark, the app in front, its first menus, and
    /// at the other end this app's own glyph with its live dot, and the clock.
    /// Returns the bar, so the window knows where the desktop starts.
    @discardableResult
    private func drawMenuBar(_ palette: DesktopPalette, now: TimeInterval) -> NSRect {
        let bar = NSRect(x: 0, y: bounds.maxY - 2.95 * u, width: bounds.width, height: 2.95 * u)
        palette.bar.setFill()
        bar.fill()

        let ink = palette.ink
        let size = 1.25 * u
        var x = bar.minX + 1.36 * u
        if let apple = symbol("apple.logo", height: 1.6 * u, color: ink.withAlphaComponent(0.82)) {
            let w = glyphWidth(apple, height: 1.6 * u)
            drawGlyph(apple, height: 1.6 * u, center: NSPoint(x: x + w / 2, y: bar.midY))
            x += w + 0.2 * u + 1.55 * u
        }
        x += text("Meetings", at: NSPoint(x: x, y: bar.midY),
                  font: .systemFont(ofSize: size, weight: .bold),
                  color: ink.withAlphaComponent(0.82)) + 1.55 * u
        for menu in ["File", "Edit", "View"] {
            x += text(menu, at: NSPoint(x: x, y: bar.midY), font: .systemFont(ofSize: size),
                      color: ink.withAlphaComponent(0.72)) + 1.55 * u
        }

        // The right half, laid out from the edge inwards.
        let clock = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .hour().minute())
        let clockFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let clockWidth = width(of: clock, font: clockFont)
        var right = bar.maxX - 1.36 * u - clockWidth
        text(clock, at: NSPoint(x: right, y: bar.midY), font: clockFont,
             color: ink.withAlphaComponent(0.72))
        right -= 1.48 * u
        if let glyph = statusGlyph(color: ink.withAlphaComponent(0.82)) {
            let box = NSRect(x: right - 1.7 * u, y: bar.midY - 0.74 * u, width: 1.7 * u, height: 1.48 * u)
            glyph.image.draw(in: box)
            // The badge: a separate dot on the glyph's top-right corner, exactly
            // as the app draws it, pulsing 1.0 → 0.25 and back over 3.6 s.
            let phase = calm ? 0 : (now.truncatingRemainder(dividingBy: 3.6)) / 3.6
            let alpha = 0.25 + 0.75 * (0.5 + 0.5 * cos(2 * .pi * phase))
            let d = 0.57 * u
            NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: alpha).setFill() // #5856d6
            NSBezierPath(ovalIn: NSRect(x: box.maxX + 0.23 * u - d, y: box.maxY + 0.11 * u - d,
                                        width: d, height: d)).fill()
        }
        return bar
    }

    /// The call, front and centre: the window the captions are running over.
    private func drawCall(_ palette: DesktopPalette, below bar: NSRect, now: TimeInterval) {
        let top: CGFloat = 2.4 * u
        let margin: CGFloat = 42
        let span = ((bounds.width - 300) * 0.9).rounded()
        let frame = NSRect(x: ((bounds.width - span) / 2).rounded(), y: margin,
                           width: span, height: bar.minY - top - margin)
        guard frame.width > 0, frame.height > 0 else { return }
        let radius = 1.25 * u
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        let ink = palette.ink

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
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 2.95 * u, width: frame.width, height: 2.95 * u)
        // Drawn upwards, so `starting` is the bottom edge and `ending` the top.
        NSGradient(starting: ink.withAlphaComponent(palette.barBottom),
                   ending: ink.withAlphaComponent(palette.barTop))?.draw(in: titleBar, angle: 90)
        ink.withAlphaComponent(palette.line).setFill()
        NSRect(x: titleBar.minX, y: titleBar.minY - px, width: titleBar.width, height: px).fill()

        let light = 1.02 * u
        for (i, colour) in [
            NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),      // #ff5f57
            NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),  // #febc2e
            NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),  // #28c840
        ].enumerated() {
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.minX + 1.48 * u + CGFloat(i) * (light + 0.68 * u),
                                        y: titleBar.midY - light / 2, width: light, height: light)).fill()
        }
        let titleFont = NSFont.systemFont(ofSize: 1.36 * u, weight: .medium)
        let title = "Weekly sync · 4 people"
        text(title, at: NSPoint(x: frame.midX - width(of: title, font: titleFont) / 2, y: titleBar.midY),
             font: titleFont, color: ink.withAlphaComponent(0.55))

        // The content: the grid of tiles, and the call's buttons under it.
        let content = NSRect(x: frame.minX, y: frame.minY, width: frame.width,
                             height: titleBar.minY - px - frame.minY)
        palette.meeting.setFill()
        content.fill()

        let button = 2.73 * u
        let controls = NSRect(x: content.minX, y: content.minY, width: content.width,
                              height: button + 2.04 * u)
        palette.recess.setFill()
        controls.fill()
        let gap = 1.02 * u
        var bx = controls.midX - (3 * button + 2 * gap) / 2
        for (name, fill, tint) in [
            ("mic.fill", ink.withAlphaComponent(0.13), ink.withAlphaComponent(0.85)),
            ("video.fill", ink.withAlphaComponent(0.13), ink.withAlphaComponent(0.85)),
            ("phone.down.fill", NSColor(srgbRed: 0.851, green: 0.282, blue: 0.247, alpha: 1), .white),
        ] {
            let circle = NSRect(x: bx, y: controls.midY - button / 2, width: button, height: button)
            fill.setFill()
            NSBezierPath(ovalIn: circle).fill()
            // At one point size for all three, the way the demo draws its three
            // in one box: the handset is a wide, low shape, and scaled to the
            // microphone's height it fills the circle.
            if let icon = symbol(name, height: button * 0.44, color: tint) {
                drawGlyph(icon, center: NSPoint(x: circle.midX, y: circle.midY))
            }
            bx += button + gap
        }

        let pad = 0.91 * u
        let between = 0.8 * u
        let grid = NSRect(x: content.minX + pad, y: controls.maxY + pad,
                          width: content.width - pad * 2,
                          height: content.maxY - controls.maxY - pad * 2)
        let tileSize = NSSize(width: (grid.width - between) / 2, height: (grid.height - between) / 2)
        // The ring a video app puts round whoever is talking, riding the voice
        // rather than sitting still: 0.85 s each way between a half-strength
        // border and a full one, with a faint halo growing under it.
        let beat = calm ? 1 : 0.5 + 0.5 * cos(.pi * (now / 0.85).truncatingRemainder(dividingBy: 2))
        for (i, person) in Self.people.enumerated() {
            let column = CGFloat(i % 2)
            let row = CGFloat(i / 2)
            let tile = NSRect(x: grid.minX + column * (tileSize.width + between),
                              y: grid.maxY - tileSize.height - row * (tileSize.height + between),
                              width: tileSize.width, height: tileSize.height)
            drawTile(tile, person: person, ring: rings[i], beat: beat, palette: palette)
        }

        // The inner ring, over the content: dark mode's faint light line inside
        // the edge, nothing at all in light.
        palette.inner.setStroke()
        let inner = NSBezierPath(roundedRect: frame.insetBy(dx: px / 4, dy: px / 4),
                                 xRadius: radius, yRadius: radius)
        inner.lineWidth = px / 2
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // And the outer one, outside the edge, taking the wallpaper's colour: a
        // Mac draws no border on a window, and this is what it draws instead.
        palette.ring.setStroke()
        let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -px / 4, dy: -px / 4),
                                xRadius: radius, yRadius: radius)
        ring.lineWidth = px / 2
        ring.stroke()
    }

    private func drawTile(_ tile: NSRect, person: (initials: String, name: String, face: [NSColor]),
                          ring: CGFloat, beat: CGFloat, palette: DesktopPalette) {
        let radius = 0.8 * u
        let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGradient(colors: palette.tile)?.draw(in: shape, angle: -60)

        // The halo, then the border — both drawn to the ring's fade, so handing
        // it on is one tile's fading out under another's fading in.
        if ring > 0 {
            let halo = NSBezierPath(roundedRect: tile.insetBy(dx: -1.5 * px, dy: -1.5 * px),
                                    xRadius: radius + px, yRadius: radius + px)
            halo.lineWidth = 2 * px
            NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 0.24 * beat * ring).setStroke()
            halo.stroke()
            let dim = NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 0.5)   // #5856d6 at ½
            let lit = NSColor(srgbRed: 0.502, green: 0.494, blue: 1, alpha: 1)         // #807eff
            let border = NSBezierPath(roundedRect: tile.insetBy(dx: 0.75 * px, dy: 0.75 * px),
                                      xRadius: radius, yRadius: radius)
            border.lineWidth = 1.5 * px
            (dim.blended(withFraction: beat, of: lit) ?? lit).withAlphaComponent(
                (0.5 + 0.5 * beat) * ring).setStroke()
            border.stroke()
        }

        let face = 3.86 * u
        let circle = NSRect(x: tile.midX - face / 2, y: tile.midY - face / 2, width: face, height: face)
        NSGradient(colors: person.face)?.draw(in: NSBezierPath(ovalIn: circle), angle: -55)
        let initialsFont = NSFont.systemFont(ofSize: 1.25 * u, weight: .semibold)
        text(person.initials, at: NSPoint(x: circle.midX - width(of: person.initials, font: initialsFont) / 2,
                                          y: circle.midY),
             font: initialsFont, color: NSColor(white: 1, alpha: 0.92))

        let nameFont = NSFont.systemFont(ofSize: 1.14 * u)
        text(person.name, at: NSPoint(x: tile.minX + 0.8 * u, y: tile.minY + 0.57 * u + nameFont.capHeight / 2),
             font: nameFont, color: palette.ink.withAlphaComponent(0.6 + 0.3 * ring))
    }

    // ── text and images ──

    /// Draw a line of text with its vertical centre on `at.y`, and say how wide
    /// it was.
    @discardableResult
    private func text(_ string: String, at: NSPoint, font: NSFont, color: NSColor) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: at.x, y: at.y - size.height / 2))
        return size.width
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    /// Icons, rasterised and measured, kept between frames: a symbol re-rendered
    /// thirty times a second would be most of the cost of drawing this.
    private var glyphs: [String: Glyph] = [:]

    /// A bitmap of an icon at screen resolution, and the bounds of the ink in
    /// it. A symbol image comes padded, with the glyph sitting on a text
    /// baseline inside its box, and drawn under the stage's scale it places
    /// itself by that baseline rather than by the rectangle it is given; a
    /// plain bitmap goes exactly where it is put, and the ink is what gets
    /// centred.
    private struct Glyph {
        let image: NSImage
        /// In the image's points.
        let ink: NSRect
    }

    /// Pixels per overlay point on the screen this is drawn on, doubled so the
    /// bitmap has something to spare when it is scaled down onto the pixel grid.
    private var raster: CGFloat { (window?.backingScaleFactor ?? 2) * max(contentScale, 0.05) * 2 }

    /// An SF Symbol at a point size, in a colour.
    private func symbol(_ name: String, height: CGFloat, color: NSColor) -> Glyph? {
        let key = "\(name)|\(height)|\(color)|\(raster)"
        if let cached = glyphs[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: height, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let glyph = rasterise(base, size: base.size, tint: nil)
        glyphs[key] = glyph
        return glyph
    }

    /// This app's own mark, from the bundle, in the bar the way the status item
    /// draws it.
    private func statusGlyph(color: NSColor) -> Glyph? {
        let size = NSSize(width: 1.7 * u, height: 1.48 * u)
        let key = "status|\(color)|\(size)|\(raster)"
        if let cached = glyphs[key] { return cached }
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "svg"),
              let base = NSImage(contentsOf: url) else { return nil }
        let glyph = rasterise(base, size: size, tint: color)
        glyphs[key] = glyph
        return glyph
    }

    /// Render an image into a bitmap `size` points across at the screen's
    /// resolution, filling it with `tint` if one is given — there, where the
    /// fill can only land on the glyph — and find the bounds of what it painted.
    private func rasterise(_ base: NSImage, size: NSSize, tint: NSColor?) -> Glyph? {
        let wide = Int((size.width * raster).rounded(.up))
        let high = Int((size.height * raster).rounded(.up))
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let pixels = NSRect(x: 0, y: 0, width: wide, height: high)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        base.draw(in: pixels)
        if let tint {
            tint.set()
            pixels.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()

        var minX = wide, minY = high, maxX = -1, maxY = -1
        if let data = rep.bitmapData {
            let row = rep.bytesPerRow
            for y in 0..<high {
                for x in 0..<wide where data[y * row + x * 4 + 3] > 16 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        // Bitmap rows run top-down; the image's points run bottom-up.
        let ink = maxX >= minX && maxY >= minY
            ? NSRect(x: CGFloat(minX) / raster, y: CGFloat(high - 1 - maxY) / raster,
                     width: CGFloat(maxX - minX + 1) / raster, height: CGFloat(maxY - minY + 1) / raster)
            : NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return Glyph(image: image, ink: ink)
    }

    /// Draw a glyph with its ink centred on `center`: at its own size, or with
    /// the ink scaled to `height` when one is given.
    private func drawGlyph(_ glyph: Glyph, height: CGFloat? = nil, center: NSPoint) {
        guard glyph.ink.height > 0 else { return }
        let scale = height.map { $0 / glyph.ink.height } ?? 1
        glyph.image.draw(in: NSRect(x: center.x - glyph.ink.midX * scale,
                                    y: center.y - glyph.ink.midY * scale,
                                    width: glyph.image.size.width * scale,
                                    height: glyph.image.size.height * scale))
    }

    private func glyphWidth(_ glyph: Glyph, height: CGFloat) -> CGFloat {
        glyph.ink.height > 0 ? glyph.ink.width * height / glyph.ink.height : 0
    }
}

// MARK: - Preview

final class SettingsPreview: NSView {
    /// Tall enough for the live box and two or three of the stack above it.
    static let displayHeight: CGFloat = 200

    private let stage = PreviewStage()
    private let box = SubtitleView(frame: .zero)
    /// The stack, in the same scroll view the overlay puts it in — so it
    /// overflows, scrolls and fades at the clipped edge the way the real one
    /// does rather than simply running out of room.
    private let scroll = HistoryScrollView()
    private let document = NSView()
    /// The blur under the live box, sampling this window's own drawing — the
    /// overlay's arrangement exactly, with the stage for a desktop. The stack's
    /// boxes carry their own, told which way to look by their style.
    private let boxBlur = BackdropBlurView(blending: .withinWindow)
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
    /// Ceiling on the near edge's fade, matching `HistoryController`: there only
    /// once the stack has been scrolled away from the live box, and much shorter.
    private static let nearFadeHeight: CGFloat = 60

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
        // the corners ended up all but square. This view is unscaled, so 8
        // points is 8 points: a little under the welcome window's 14, at a
        // little under its width. The hairline is that demo's frame, for the
        // same reason it has one: at this weight the screen and the window
        // behind the settings need an edge between them.
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
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

        // The stack below the live box, so a sentence growing to three lines
        // rides over the stack rather than being hidden behind it; the blur
        // under the box, told its shape by the box, as on the overlay.
        box.backdrop = boxBlur
        stage.addSubview(scroll)
        stage.addSubview(boxBlur)
        stage.addSubview(box, positioned: .above, relativeTo: boxBlur)
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
        case .lines, .background, .blur, .reveal:
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
        case .blur:
            let points = Int(style.blur.rounded())
            return points == 0
                ? "No blur. The picture shows through the pill exactly as it is."
                : "The picture behind the pill is softened by \(points) point\(points == 1 ? "" : "s")."
        case .reveal:
            guard style.revealEnabled else {
                return "The box stays solid under the pointer. Move it instead: hold ⇧ and drag."
            }
            return "Point at the box and this much of it dissolves, this far around the pointer."
        case .keep:
            guard style.historyEnabled, style.historyDepth > 0 else {
                return "⌥ brings nothing back. Finished boxes are gone once they clear."
            }
            switch style.historyDepth {
            case 1:
                return "⌥ brings back the last box."
            case OverlayController.unlimitedHistoryDepth:
                return "⌥ brings back every box, newest first, and scrolls through them."
            case let n:
                return "⌥ brings back the last \(n) boxes, newest first, and scrolls through them."
            }
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
        boxBlur.radius = style.blur
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
        // The same frame as the box, so the shape the box hands it lands where
        // the box draws it — the pill inside the ⇧ ring's margin.
        boxBlur.frame = box.frame

        layoutStack(above: box.frame.maxY - SubtitleView.pad)
        syncStack()
        updateMask()
    }

    /// Build the stack, and frame the scroll view against the live box.
    ///
    /// The document holds every box the depth allows, not only the ones that
    /// fit: what does not fit is what the wheel is for.
    private func layoutStack(above top: CGFloat) {
        // Unlimited is a sentinel far beyond anything `closed` holds, and
        // `suffix` is happy to be asked for more than there is.
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
            textOpacity: style.historyTextOpacity,
            blur: style.blur,
            // The stage is the boxes' desktop, and it is this window's own drawing.
            backdrop: .withinWindow)

        let key = "\(visible.joined(separator: "\u{1}"))|\(pillStyle.fontSize)|\(pillStyle.maxLines)"
            + "|\(pillStyle.fill)|\(pillStyle.textOpacity)|\(ceiling)"
        if key != pillKey {
            pillKey = key
            rebuild(visible, style: pillStyle)
        }

        // Room between the live box and the menu bar. The live box grows
        // upwards as a sentence wraps, so this shrinks under it — which is why
        // the height is re-derived here rather than set once.
        let bottom = top + Self.gap
        let room = max(0, stage.bounds.height - stage.menuBarHeight - bottom)
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
        // The stack always sits above the live box here, so the far edge is the
        // top and the near edge the bottom.
        let farHidden = contentHeight - visible.maxY
        let nearHidden = visible.minY

        // Nothing behind either edge — including the case where the whole stack
        // fits. A fade with nothing behind it promises more and does not deliver.
        guard visible.height > 0, contentHeight > visible.height + 1,
              farHidden > 0.5 || nearHidden > 0.5 else {
            for pill in pills { pill.wear(nil) }
            return
        }

        // Each band is capped at half the height, so the two can meet but never
        // cross.
        let far = farHidden > 0.5 ? min(min(Self.fadeHeight, farHidden), visible.height / 2) : 0
        let near = nearHidden > 0.5 ? min(min(Self.nearFadeHeight, nearHidden), visible.height / 2) : 0
        let farStop = far / visible.height
        let nearStop = near / visible.height

        let clear = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor
        // Bottom to top. A band of zero is left out rather than written as a
        // zero-width ramp, which would put a clear stop on the very edge row.
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        if nearStop > 0 {
            colors += [clear, solid]
            locations += [0, NSNumber(value: Double(nearStop))]
        } else {
            colors.append(solid)
            locations.append(0)
        }
        if farStop > 0 {
            colors += [solid, clear]
            locations += [NSNumber(value: Double(1 - farStop)), 1]
        } else {
            colors.append(solid)
            locations.append(1)
        }
        // Worn by each box, as on the overlay — see StackFade.
        let fade = StackFade(visible: visible, colors: colors, locations: locations)
        for pill in pills { pill.wear(fade) }
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
