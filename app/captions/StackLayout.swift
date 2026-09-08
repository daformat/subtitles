// Where the ⌥ stack and its boxes go, sideways.
//
// The stack is a panel as wide as its widest box, and every box in it is
// centred on the live box's anchor. Two things about that are easy to get
// wrong, and both were, for a while:
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
// Here rather than in History.swift so it can be tested: the drift was found
// by eye, and eyes are how it would have come back.

import Foundation

public enum StackLayout {
    /// The panel's x for a stack `width` wide centred on `centreX`. Whole
    /// points, so the panel is never drawn on a half pixel.
    public static func panelX(centreX: CGFloat, width: CGFloat) -> CGFloat {
        (centreX - width / 2).rounded()
    }

    /// Where a box `boxWidth` wide goes on screen to be centred on `centreX`:
    /// its own rounding, independent of the panel it sits in.
    public static func boxScreenX(centreX: CGFloat, boxWidth: CGFloat) -> CGFloat {
        (centreX - boxWidth / 2).rounded()
    }

    /// The box's x *inside* a panel at `panelX`: whatever puts it at
    /// `boxScreenX`. Not `(panelWidth - boxWidth) / 2` rounded, which is the
    /// same number only while the panel's width and the box's have the same
    /// parity.
    public static func boxX(centreX: CGFloat, panelX: CGFloat, boxWidth: CGFloat) -> CGFloat {
        boxScreenX(centreX: centreX, boxWidth: boxWidth) - panelX
    }
}
