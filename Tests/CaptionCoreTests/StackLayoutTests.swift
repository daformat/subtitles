// The ⌥ stack's boxes stay put sideways, whatever the stack around them does.
//
// The two invariants below are the whole point of StackLayout: a box's place
// on screen depends on the centre and its own width, and on nothing else. The
// last test keeps the two ways this was broken, so that the reason is in the
// suite and not only in a commit message.

import XCTest
@testable import CaptionCore

final class StackLayoutTests: XCTestCase {
    private let centre: CGFloat = 800

    /// Where a box ends up on screen, through the panel: the panel's x plus
    /// the box's x inside it.
    private func onScreen(box: CGFloat, stack: CGFloat) -> CGFloat {
        let panel = StackLayout.panelX(centreX: centre, width: stack)
        return panel + StackLayout.boxX(centreX: centre, panelX: panel, boxWidth: box)
    }

    func testABoxIsWhereItIsWhateverTheStacksWidth() {
        for box: CGFloat in [120, 121, 200, 201, 333] {
            let alone = onScreen(box: box, stack: box)
            for stack: CGFloat in [box, box + 1, box + 2, box + 99, box + 100, 1000] {
                XCTAssertEqual(onScreen(box: box, stack: stack), alone,
                               "a \(box) box moved when the stack was \(stack) wide")
            }
        }
    }

    func testEveryBoxIsCentred() {
        for box: CGFloat in [120, 121, 200, 201] {
            let x = onScreen(box: box, stack: 400)
            // Whole-point origins put an odd box's centre half a point off.
            // What matters is that it is the *same* half point every time.
            XCTAssertEqual(x + box / 2, centre, accuracy: 0.5)
            XCTAssertEqual(x, StackLayout.boxScreenX(centreX: centre, boxWidth: box))
        }
    }

    func testAWiderBoxArrivingLeavesTheOthersStill() {
        let before = [200, 240].map { onScreen(box: $0, stack: 240) }
        let after = [200, 240].map { onScreen(box: $0, stack: 331) }
        XCTAssertEqual(before, after)
    }

    func testTheWidestBoxLeavingLeavesTheOthersStill() {
        let before = [200, 240].map { onScreen(box: $0, stack: 331) }
        let after = [200, 240].map { onScreen(box: $0, stack: 240) }
        XCTAssertEqual(before, after)
    }

    /// The panel's origin comes from the centre and the width on every frame.
    /// While the centre is in flight the boxes travel with it as one body;
    /// while only the width changes, nothing on screen moves at all.
    func testTheOriginFollowsTheCentreNotTheOtherWayRound() {
        let box: CGFloat = 200
        // Mid-flight, the centre is wherever the spring has it.
        for sprung: CGFloat in [780, 790.4, 799.9, 800] {
            let narrow = StackLayout.panelX(centreX: sprung, width: 240)
                + StackLayout.boxX(centreX: sprung, panelX: StackLayout.panelX(centreX: sprung, width: 240), boxWidth: box)
            let wide = StackLayout.panelX(centreX: sprung, width: 331)
                + StackLayout.boxX(centreX: sprung, panelX: StackLayout.panelX(centreX: sprung, width: 331), boxWidth: box)
            XCTAssertEqual(narrow, wide, "the width moved a box at centre \(sprung)")
            XCTAssertEqual(narrow, StackLayout.boxScreenX(centreX: sprung, boxWidth: box))
        }
    }

    /// The two ways the stack used to drift, kept so the reason stays in the
    /// suite. Neither formula is used any more; this is what they did.
    func testWhyTheStackUsedToSlide() {
        let box: CGFloat = 200

        // 1. The panel's origin was the sprung quantity. When a 331-wide box
        //    arrived in a 240-wide stack, the boxes were re-centred in the new
        //    width at once while the origin was still on its way: for the
        //    first frame, every box sat half the width change to the right.
        let oldOrigin = (centre - 240 / 2).rounded()          // where the spring still was
        let newInset = ((331 - box) / 2).rounded()            // where the box was put inside
        let drifted = oldOrigin + newInset
        let settled = (centre - 331 / 2).rounded() + newInset
        XCTAssertEqual(drifted - settled, (331 - 240) / 2, accuracy: 0.5)
        XCTAssertNotEqual(drifted, settled)

        // 2. Origin and inset rounded separately: with the stack 301 wide the
        //    box landed a point to the right of where it did at 300.
        func separately(stack: CGFloat) -> CGFloat {
            (centre - stack / 2).rounded() + ((stack - box) / 2).rounded()
        }
        XCTAssertEqual(separately(stack: 300), 700)
        XCTAssertEqual(separately(stack: 301), 701)
        XCTAssertEqual(onScreen(box: box, stack: 300), onScreen(box: box, stack: 301))
    }
}
