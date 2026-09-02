// Where the live box's page begins.
//
// This is the half of the paging that had no tests, and the bug that got through
// was a repaint that was not idempotent: toggling ⌃ re-paged from the top and
// consumed carry state as it went, so each press broke the pages somewhere new
// and left the anchor further along than it found it. A few presses walked the
// box forward until only the newest clause was left. The first test here is that
// one, written as the property it violated.

import XCTest
@testable import CaptionCore

final class PageAnchorTests: XCTestCase {
    private func fits(_ capacity: Int) -> ([String]) -> Int {
        { texts in min(capacity, texts.count) }
    }

    private func stream(_ clauses: [[String]]) -> (words: [TimedWord], starts: [TimeInterval]) {
        var words: [TimedWord] = []
        var starts: [TimeInterval] = []
        for (index, clause) in clauses.enumerated() {
            let base = Double(index) * 10
            starts.append(base)
            for (offset, text) in clause.enumerated() {
                words.append(TimedWord(text: text, start: base + Double(offset),
                                       end: base + Double(offset) + 0.5))
            }
        }
        return (words, starts)
    }

    private let sample = [["the", "cat", "sat", "down"], ["and", "then", "it", "slept"],
                          ["until", "the", "sun", "rose"], ["over", "the", "quiet", "hills"]]

    private func text(_ page: PageAnchor.Page) -> String {
        page.visible.map(\.text).joined(separator: " ")
    }

    // MARK: repainting

    /// The transcript arrives whole on every update, so an idle recogniser
    /// repeats itself several times a second and a repaint must cost nothing.
    func testPagingTheSameWordsTwiceGivesTheSamePage() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let first = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        let second = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertEqual(text(first), text(second))
        XCTAssertFalse(second.brokePage, "a repaint should not close a page")
    }

    /// The ⌃ bug, as a property: repainting many times must not walk the box
    /// forward through the transcript.
    func testRepeatedRepaintsDoNotAdvanceThePage() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let settled = text(anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5)))
        for _ in 0..<20 {
            let again = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
            XCTAssertEqual(text(again), settled)
        }
    }

    /// Growing the transcript should extend the page, not restart it.
    func testGrowingTheTranscriptKeepsTheAnchor() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(Array(words.prefix(6)), chunkStarts: starts, allowCarry: true, fits: fits(5))
        let before = anchor.start
        _ = anchor.page(Array(words.prefix(7)), chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertGreaterThanOrEqual(anchor.start, before)
    }

    // MARK: what ends up on screen

    func testAShortTranscriptAllFits() {
        let (words, starts) = stream([sample[0]])
        var anchor = PageAnchor()
        let page = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(10))
        XCTAssertEqual(text(page), "the cat sat down")
        XCTAssertFalse(page.brokePage)
    }

    func testOverflowKeepsTheNewestWords() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let page = anchor.page(words, chunkStarts: starts, allowCarry: false, fits: fits(5))
        XCTAssertTrue(page.brokePage)
        let all = words.map(\.text).joined(separator: " ")
        XCTAssertTrue(all.hasSuffix(text(page)), "the page should be the tail of the transcript")
        XCTAssertLessThan(page.visible.count, words.count)
    }

    /// A page that fills restarts at the last clause it showed, rather than at the
    /// word that spilled, so the box opens on a whole clause and not mid-phrase.
    func testCarryKeepsThePageClauseAligned() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let page = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertTrue(starts.contains(anchor.start),
                      "page began at \(anchor.start), which is not a clause boundary")
        XCTAssertEqual(text(page), "over the quiet hills")
    }

    /// Never out of a box that has faded: whatever was in it is gone from the
    /// screen and from the reader.
    func testNoCarryWhenTheCallerForbidsIt() {
        let (words, starts) = stream(sample)
        var carried = PageAnchor()
        var plain = PageAnchor()
        let withCarry = carried.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        let without = plain.page(words, chunkStarts: starts, allowCarry: false, fits: fits(5))
        XCTAssertNotEqual(text(withCarry), text(without))
        XCTAssertFalse(starts.contains(plain.start),
                       "without a carry the page should break where the text spilled")
    }

    // MARK: fresh pages

    /// A pause or an endpoint: the next words are a new thought and start their
    /// own box rather than continuing one nobody is still reading.
    func testMarkFreshStartsAfterEverythingSeen() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        anchor.markFresh()

        let next = [TimedWord(text: "afterwards", start: 100, end: 100.5)]
        let page = anchor.page(next, chunkStarts: [100], allowCarry: true, fits: fits(5))
        XCTAssertEqual(text(page), "afterwards")
    }

    /// Fresh must not replay the whole transcript: engines that never reset keep
    /// growing one, so "fresh" means the words after this moment in the audio.
    func testMarkFreshDoesNotReplayThePast() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        anchor.markFresh()

        let grown = words + [TimedWord(text: "afterwards", start: 100, end: 100.5)]
        let page = anchor.page(grown, chunkStarts: starts, allowCarry: true, fits: fits(50))
        XCTAssertEqual(text(page), "afterwards")
    }

    // MARK: restarts and swaps

    /// The recogniser resets its transcript at an endpoint and times begin again
    /// near zero, so the old anchor points into audio that is gone.
    func testATranscriptThatGoesBackwardsRestarts() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertGreaterThan(anchor.start, 0)

        let fresh = [TimedWord(text: "again", start: 0, end: 0.5)]
        let page = anchor.page(fresh, chunkStarts: [0], allowCarry: true, fits: fits(5))
        XCTAssertEqual(text(page), "again")
    }

    /// A carry bar recorded before a restart sits far in the future of the new
    /// timeline, and would otherwise refuse every carry for the rest of a session.
    func testCarryWorksAgainAfterARestart() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(6))

        // Same shape of transcript, times back near zero. A carry bar left over
        // from the old timeline would refuse every carry from here on, so the
        // result must match what an anchor that had never seen anything produces.
        let (again, againStarts) = stream(sample)
        let page = anchor.page(again, chunkStarts: againStarts, allowCarry: true, fits: fits(5))

        var pristine = PageAnchor()
        let expected = pristine.page(again, chunkStarts: againStarts, allowCarry: true, fits: fits(5))
        XCTAssertEqual(text(page), text(expected))
        XCTAssertEqual(anchor.start, pristine.start)
    }

    /// The translated stream ends at the last settled clause while the spoken one
    /// runs ahead of it, so a swap looks like a transcript going backwards unless
    /// the progress figure is dropped with it.
    func testForgetProgressStopsASwapLookingLikeARestart() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        let kept = anchor.start

        anchor.forgetProgress()
        let shorter = Array(words.prefix(12))     // the other rendering, a clause behind
        _ = anchor.page(shorter, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertGreaterThanOrEqual(anchor.start, kept, "the swap restarted the page")
    }

    func testRewindGoesBackToTheBeginning() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertGreaterThan(anchor.start, 0)
        anchor.rewind()
        XCTAssertEqual(anchor.start, 0)
    }

    // MARK: degenerate input

    func testNoWordsIsNotAPage() {
        var anchor = PageAnchor()
        let page = anchor.page([], chunkStarts: [], allowCarry: true, fits: fits(5))
        XCTAssertTrue(page.visible.isEmpty)
        XCTAssertFalse(page.brokePage)
    }

    /// One word wider than the box: paging cannot help, and looping forever
    /// trying is the failure that matters.
    func testAWordWiderThanTheBoxTerminates() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let page = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: { _ in 0 })
        XCTAssertFalse(page.visible.isEmpty)
    }

    func testBoundariesOnEveryPageStartTerminate() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        let page = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(3))
        XCTAssertFalse(page.visible.isEmpty)
    }
}
