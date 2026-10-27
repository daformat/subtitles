// Where the ⌥ stack and its boxes go, sideways.
//
// The stack is a panel as wide as its widest box, and by default every box in
// it is centered on the live box's anchor. Two things about that are easy to
// get wrong, and both were, for a while:
//
// The panel's width changes whenever a wider box arrives or the widest one
// leaves, so the panel's *origin* moves even though nothing on screen should.
// A panel whose origin is what gets animated slides every box sideways by half
// the change in width and back again, over the tenth of a second the spring
// takes. So the quantity that moves is the centre, and the origin is derived
// from it and the width on every frame: a width change moves the origin at
// once, with the boxes staying exactly where they were.
//
// And the origin and each box's offset inside the panel are both rounded to
// whole points, which is right — a half-point origin blurs a panel — but
// rounding the two separately puts a box's centre a point off whenever the
// panel's width changes parity. So a box's *screen* position is rounded from
// the centre directly, and its offset inside the panel is whatever gets it
// there.
//
// Lined up on a side instead, the boxes share the edge the widest box the
// stack can hold would have: the anchor less or plus half the stack's ceiling,
// which is narrower than the live box's, its text being smaller. Not the live
// box's edge, which moves with every word, and not the widest box's, which
// moves whenever one arrives or leaves. So the same rule holds: a box's place depends on the
// center and its own width, and on nothing the stack around it does. The panel
// is placed as if it were a box as wide as the stack.
//
// The search pill stays centered on the live box whichever side the boxes
// take, so a stack lined up on a side has a panel wide enough for both
// (`panel`).
//
// Here rather than in History.swift so it can be tested: the drift was found
// by eye, and eyes are how it would have come back.

import Foundation

public enum StackLayout {
    /// Which side of the stack its boxes line up on. Chosen in
    /// Settings ▸ UI ▸ Recent Boxes.
    public enum Alignment: String, CaseIterable, Codable, Sendable {
        /// The edge lines start from: the left, or the right for Arabic and
        /// Hebrew, as the text's own start alignment reads it. The default.
        case start
        /// Centered on the live box, as the stack was before this setting.
        case center
        case end
    }

    /// The side `alignment` comes to in text running `rtl`: -1 the left, 1
    /// the right, 0 the middle.
    private static func side(_ alignment: Alignment, rtl: Bool) -> CGFloat {
        switch alignment {
        case .center: return 0
        case .start: return rtl ? 1 : -1
        case .end: return rtl ? -1 : 1
        }
    }

    /// Whether `alignment` is the right side in text running `rtl`; nil for
    /// the middle.
    public static func isOnRight(_ alignment: Alignment, rtl: Bool) -> Bool? {
        let edge = side(alignment, rtl: rtl)
        return edge == 0 ? nil : edge > 0
    }

    /// The panel's x for a stack `width` wide centered on `centreX`, or flush
    /// with one side of a `column` that wide centered there. Whole points, so
    /// the panel is never drawn on a half pixel.
    public static func panelX(centreX: CGFloat, width: CGFloat, column: CGFloat = 0,
                              alignment: Alignment = .center, rtl: Bool = false) -> CGFloat {
        boxScreenX(centreX: centreX, boxWidth: width, column: column,
                   alignment: alignment, rtl: rtl)
    }

    /// Where a box `boxWidth` wide goes on screen to be centered on `centreX`,
    /// or flush with the side of `column` that `alignment` names: its own
    /// rounding, independent of the panel it sits in.
    public static func boxScreenX(centreX: CGFloat, boxWidth: CGFloat, column: CGFloat = 0,
                                  alignment: Alignment = .center, rtl: Bool = false) -> CGFloat {
        let edge = side(alignment, rtl: rtl)
        return (centreX + edge * column / 2 - (edge + 1) * boxWidth / 2).rounded()
    }

    /// The panel for a stack `width` wide at `alignment` that also holds a
    /// pill up to `centred` wide centered on `centreX`: its x, and a width
    /// that is the same wherever the centre is, so a panel following the
    /// live box on a spring moves without resizing. Taken from the unrounded
    /// edges, whose span does not change with the centre, and a point over,
    /// which is the most the rounding of either can push past it.
    public static func panel(centreX: CGFloat, width: CGFloat, centred: CGFloat,
                             column: CGFloat = 0, alignment: Alignment = .center,
                             rtl: Bool = false) -> (x: CGFloat, width: CGFloat) {
        let edge = side(alignment, rtl: rtl)
        let boxes = centreX + edge * column / 2 - (edge + 1) * width / 2
        let pill = centreX - centred / 2
        let left = min(boxes, pill)
        // To a thousandth first: the span is the same at every centre only
        // on paper, and a few ulps over a whole number rounds up a point.
        let span = ((max(boxes + width, pill + centred) - left) * 1000).rounded() / 1000
        return (left.rounded(), span.rounded(.up) + 1)
    }

    /// The box's x *inside* a panel at `panelX`: whatever puts it at
    /// `boxScreenX`. Not `(panelWidth - boxWidth) / 2` rounded, which is the
    /// same number only while the panel's width and the box's have the same
    /// parity.
    public static func boxX(centreX: CGFloat, panelX: CGFloat, boxWidth: CGFloat,
                            column: CGFloat = 0, alignment: Alignment = .center,
                            rtl: Bool = false) -> CGFloat {
        boxScreenX(centreX: centreX, boxWidth: boxWidth, column: column,
                   alignment: alignment, rtl: rtl) - panelX
    }
}
