// The red badge on the status icon, for whatever is waiting on the person:
// an update found and not installed, or a key to enter once the trial is
// over. One mark with a count in it rather than one per cause: the corner
// has room for one, and two things waiting is a 2.
//
// Not one of the menu bar's own badge states (MenuBar.swift): those say what
// the app is doing and swap at the top right, while this says nothing about
// that and has to be visible through all of them, listening included, or it
// is visible only when nothing is playing. So it is a second mark at the top
// *left*, the corner the health badge leaves free.
//
// Red, with a count in it — and red is the colour MenuBar.swift says never
// to use. The exception holds because this is not a dot: a red disc with a
// white digit in it is the shape every notification badge on the Mac has,
// and it reads as "something waiting for you", not as a state light. A plain
// red dot in this corner would read as recording, and a teal one, tried
// first, was simply not noticed.

import AppKit

final class AttentionBadge {
    private lazy var badge = CountBadgeView(count: 1)

    /// Place the badge for `count` things waiting, or take it down for none.
    func decorate(_ button: NSStatusBarButton, glyph: NSRect, count: Int) {
        guard count > 0 else {
            badge.removeFromSuperview()
            return
        }
        badge.count = count
        if badge.superview == nil { button.addSubview(badge) }
        let size = CountBadgeView.size
        // Overhanging the corner a little more than a dot would, as
        // notification badges do.
        let y = button.isFlipped ? glyph.minY - 2 : glyph.maxY - size + 2
        badge.frame = NSRect(x: glyph.minX - 3, y: y, width: size, height: size)
    }
}

/// A notification badge: a red disc with a white count centred in it.
///
/// Drawn rather than composed from a layer and a label, so the digit is set
/// against the disc at the exact size and cannot drift off centre with a
/// font change. Eleven points is the smallest at which a bold digit is a digit
/// rather than a smudge on a menu bar.
final class CountBadgeView: NSView {
    static let size: CGFloat = 11

    var count: Int {
        didSet { if count != oldValue { needsDisplay = true } }
    }

    init(count: Int) {
        self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        // The digit is drawn as a glyph at a baseline of this view's choosing,
        // not as a string: string drawing goes through the layout manager,
        // which rounds the baseline to whole pixels and lands the ink a
        // fraction high or low at this size. Centred on the glyph's ink, not
        // its typographic box — a 1 has its flag on the left and its stem right
        // of centre, and the box carries ascent and descent no digit fills.
        // All of it is the font's numbers, so another face or size still
        // lands centred.
        let font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        var glyph = CGGlyph(0)
        var scalar = Array(String(count).utf16)[0]
        CTFontGetGlyphsForCharacters(font, &scalar, &glyph, 1)
        let ink = font.boundingRect(forCGGlyph: glyph)
        // A 1 sits half a point left of the ink's centre: it carries its weight
        // in the stem, right of its box's middle, and centred by the box it
        // reads as sitting right of the disc's. A 2 is even and needs no help.
        let nudge: CGFloat = count == 1 ? -0.5 : 0
        var origin = CGPoint(x: bounds.midX - ink.midX + nudge, y: bounds.midY - ink.midY)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.white.cgColor)
        CTFontDrawGlyphs(font, &glyph, &origin, 1, ctx)
    }
}
