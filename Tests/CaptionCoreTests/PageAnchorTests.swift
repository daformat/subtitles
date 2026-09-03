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

    // MARK: the unsettled tail

    /// Reproduces what the log showed: only the tail is being translated, it grows
    /// a word at a time, and it is re-spread across the audio it covers on every
    /// update, so every one of its words gets a new time each pass. Breaking
    /// inside that cannot hold, and the same words came back box after box while
    /// the speaker added nothing.
    func testAGrowingTailDoesNotRepeatItself() {
        let settled = stream([sample[0], sample[1]])
        var anchor = PageAnchor()
        var seen: [String] = []

        let tailWords = ["a", "b", "c", "d", "e", "f", "g", "h"]
        for count in 1...tailWords.count {
            // The tail spans a fixed stretch of audio and is spread across it, so
            // adding a word moves every word already in it.
            let span = 5.0
            let step = span / Double(count)
            let tail = (0..<count).map { index in
                TimedWord(text: tailWords[index], start: 100 + step * Double(index),
                          end: 100 + step * Double(index + 1))
            }
            let page = anchor.page(settled.words + tail, chunkStarts: settled.starts,
                                   allowCarry: true, speculativeFrom: 100, fits: fits(6))
            seen.append(contentsOf: page.closed.map { $0.map(\.text).joined(separator: " ") })
        }

        for box in seen {
            for word in box.split(separator: " ") {
                XCTAssertFalse(tailWords.contains(String(word)),
                               "unsettled word '\(word)' left the screen in box '\(box)'")
            }
        }
    }

    /// The page may reach the tail but never pass into it, however little of the
    /// box the settled text occupies.
    func testThePageNeverBreaksInsideTheTail() {
        let settled = stream([sample[0], sample[1], sample[2]])
        let tail = (0..<12).map {
            TimedWord(text: "t\($0)", start: 100 + Double($0) * 0.1,
                      end: 100 + Double($0) * 0.1 + 0.1)
        }
        var anchor = PageAnchor()
        for _ in 0..<10 {
            _ = anchor.page(settled.words + tail, chunkStarts: settled.starts,
                            allowCarry: true, speculativeFrom: 100, fits: fits(4))
            XCTAssertLessThanOrEqual(anchor.start, 100,
                                     "the anchor moved into provisional text")
        }
    }

    /// With no tail declared, paging is unchanged.
    func testAbsentTailLeavesPagingAlone() {
        let (words, starts) = stream(sample)
        var bounded = PageAnchor()
        var plain = PageAnchor()
        let a = bounded.page(words, chunkStarts: starts, allowCarry: true,
                             speculativeFrom: .greatestFiniteMagnitude, fits: fits(5))
        let b = plain.page(words, chunkStarts: starts, allowCarry: true, fits: fits(5))
        XCTAssertEqual(text(a), text(b))
    }

    // MARK: nothing comes back from a box that has gone

    /// A fade closes the box, and what was in it is gone as far as the reader is
    /// concerned. The tail spans the fade, though, and is re-timed on every
    /// update, so words that sat before the anchor drifted after it and reappeared
    /// at the top of the next box.
    func testAFadedBoxDoesNotComeBackThroughTheTail() {
        let settled = stream([sample[0]])
        let stale = sample[1]

        /// The tail always begins at 10 and is spread across however much audio it
        /// has reached, so every word in it moves as it grows.
        func tail(_ count: Int) -> [TimedWord] {
            let step = 8.0 / Double(count)
            return (0..<count).map { index in
                TimedWord(text: stale[index], start: 10 + step * Double(index),
                          end: 10 + step * Double(index) + 0.4)
            }
        }

        var anchor = PageAnchor()
        _ = anchor.page(settled.words + tail(1), chunkStarts: settled.starts,
                        allowCarry: true, speculativeFrom: 10, fits: fits(20))
        anchor.markFresh()                       // the box faded

        for count in 2...stale.count {
            let page = anchor.page(settled.words + tail(count), chunkStarts: settled.starts,
                                   allowCarry: true, speculativeFrom: 10, fits: fits(20))
            let shown = text(page).split(separator: " ").map(String.init)
            for word in stale {
                XCTAssertFalse(shown.contains(word),
                               "'\(word)' returned from a faded box as '\(text(page))'")
            }
            for word in sample[0] {
                XCTAssertFalse(shown.contains(word),
                               "settled '\(word)' returned from a faded box")
            }
        }
    }

    /// Nothing settled from before the fade comes back either.
    func testAFadedBoxDoesNotComeBackThroughSettledText() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(50))
        anchor.markFresh()

        let page = anchor.page(words + [TimedWord(text: "after", start: 100, end: 100.5)],
                               chunkStarts: starts, allowCarry: true, fits: fits(50))
        XCTAssertEqual(text(page), "after")
    }

    /// Once the speaker has produced a tail that begins after the fade, it shows.
    func testAFreshTailAfterAFadeIsShown() {
        let (words, starts) = stream(sample)
        var anchor = PageAnchor()
        _ = anchor.page(words, chunkStarts: starts, allowCarry: true, fits: fits(50))
        anchor.markFresh()

        let fresh = [TimedWord(text: "nouveau", start: 100, end: 100.5)]
        let page = anchor.page(words + fresh, chunkStarts: starts, allowCarry: true,
                               speculativeFrom: 100, fits: fits(50))
        XCTAssertEqual(text(page), "nouveau")
    }
}
